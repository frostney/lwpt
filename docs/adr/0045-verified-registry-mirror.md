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
adding `upstream`, `trust_key_id`, `trust_public_key`, `max_store_bytes`, and
`max_sync_bytes` to the operational configuration. Reconfiguration cannot
change an initialized role, origin identity, or root pin. An upstream URL and
the byte budgets may change without changing identity. Mirror initialization
does not generate a private seed, and publication, checkpoint renewal, and key
rotation are disabled for the mirror role. HTTPClient connects over IPv4 only,
so a bracketed IPv6 upstream is rejected at configuration time instead of
failing later at synchronization.

`LWPT.Registry.Verification` owns the signed read contract. Discovery and
capabilities use its bounded canonical parser; checkpoint inspection returns
explicitly untrusted retrieval hints. Successful proof verification binds
origin, root trust, snapshot history, records, and the same raw archive SHA-256
used by the content-addressed cache. A second attestation format is unnecessary.
The parser rejects comments outside quoted strings, invalid UTF-8, and any
structure deeper than three levels below the root. The depth bound is enforced
inside the TOML parser, so dotted keys cannot build nesting that bracket
counting misses.

Synchronization retains hash-verified metadata and archives at the existing
content-addressed paths. Cached objects are reverified before reuse. Exact
checkpoint and signature bytes use content-addressed renewal paths, so a
same-sequence renewal cannot overwrite an earlier accepted proof. Key records,
rotation documents, and rotation signatures are stored by their own SHA-256
under `proofs/sha256/`. The mirror state (`lwpt-registry-mirror-state-v1`)
records its role explicitly and binds the exact accepted proof: the checkpoint
hash, the root key record's hash, and, for each accepted rotation, its
sequence and the hashes of the rotation document, both signatures, and the new
key's record. Verification reads only those bound hashes. A file left by an
unaccepted attempt can therefore never join the accepted rotation chain, and
an unsigned key record never acquires authority through a fixed path: the next
synchronization rebinds whatever record the upstream currently serves, after
validating it against the pin. One atomic `state/current.toml` replacement
activates the complete result. Files verified during an interrupted attempt
remain available to its retry; a failed attempt does not replace the active
pointer.

The mirror serves only the current checkpoint and signature pair, and only
the snapshots, records, and archives in that checkpoint's verified history.
Cached candidates are not addressable by their hash paths: a record or archive
outside accepted history returns 404 like any other unknown resource.
Optional historical checkpoint URLs are not supported; previously accepted
snapshot ancestors remain readable. The upstream key record is fetched under
the 1 MiB control-document limit and checked against the immutable pin and
checkpoint sequence. The same rule applies to rotated key records and
dual-signed rotation triplets. Their HTTP routes expose only the bound chain.

The server classifies each request target before it captures any state, so
unknown or malformed routes never load or verify retained proof. A mirror
verifies its complete retained proof once per accepted state and shares that
immutable generation with every request that captures the same
`state/current.toml` bytes. Generation construction is serialized per store,
so concurrent requests after an activation perform one verification, and
waiting requests keep observing their own deadlines. Each served resource is
opened against the digest authenticated when the generation was built. Bytes
replaced afterwards are refused with `resource_hash_mismatch` instead of being
served. Origins keep verifying the current checkpoint on every request and
share one bounded history verification per accepted head for snapshot, record,
and object membership. Pending origin snapshots remain hidden.

Publication and local key rotation validate the complete candidate history
with the serving verifier and its limits before writing the checkpoint that
would name it. A head that serving would refuse is never activated, and the
previous pointer remains current.

`state/sync-attempt.toml` records the current attempt separately from the
accepted state. After acquiring the publication lease, synchronization writes
an `attempt_id`, `started_at`, and `outcome = "in_progress"`. It then records
`verified`, `activated`, or `failed` with the original error. Recording an
outcome is best-effort: if that write fails, synchronization reports its own
failure rather than the recording error. When a process opens a mirror whose
record is still `in_progress` while the lease is free, it marks that attempt
`abandoned`. An attempt marked `verified` is not activation proof; the current
pointer and its successful sync time remain authoritative. Writes use the
existing atomic helpers. These provide process-interruption recovery and
atomic visibility, not a power-loss guarantee: ordinary resource writes do not
currently flush files and directory entries with `fsync` or its platform
equivalent.

## Transfer and freshness bounds

Metadata verification stays serial. Missing archives are deduplicated by their
authenticated hash; conflicting signed sizes fail before any archive request.
The archive path admits pairs of at most two private workers through HTTPClient's
whole-body API. Each worker owns its request, bytes, verification and error.
Only the coordinator adopts verified objects or changes the activation pointer.
A pair drains before another pair starts. Failed transfers stop further
admission, but successful siblings remain available for retry. Active requests
are joined under their existing deadlines; synchronous system DNS resolution
is still outside the transport's enforceable deadline.

Archives are limited to 256 MiB individually and in aggregate across admitted
workers. Each response is capped at its signed archive size. Reservations use
overflow-safe Int64 arithmetic and remain charged through completion, adoption
and buffer release. A completed sibling therefore cannot admit extra bytes
while another transfer is still active. A conservative four-copy allowance for
HTTP framing and conversion gives a 1 GiB payload envelope, not a measured RSS
limit or a guarantee of allocation success on 32-bit systems. Metadata, TLS,
allocator fragmentation and runtime state require separate headroom. FPC 3.2.2's
read-only `TBytesStream` initially shares its supplied dynamic array; it does
not eagerly copy the archive. Native 32-bit allocation validation remains
required before making a stronger memory claim.

Disk use has two operator-configurable budgets, set with
`registry init --role mirror --max-store-bytes <n> --max-sync-bytes <n>`.
`max_store_bytes` bounds the whole data directory and defaults to 32 GiB.
`max_sync_bytes` bounds what one synchronization may add and defaults to
8 GiB; it must be at least 1 MiB and no larger than the store budget. Every new
metadata document is charged before it is written. The complete authenticated
archive plan is reserved before the first archive request, so an oversized
plan fails without transferring anything. Unaccepted candidates are kept for
retry only while a complete attempt still fits. When the data directory has
less than one attempt budget of headroom, synchronization first removes
content outside the accepted generation, then reserves.

Discovery, checkpoint, key, rotation, signature, and
rotation-page control documents are limited to 1 MiB. The shared verifier
limits a complete proof to 64 MiB, 10,000 documents, and 1,000 rotations;
content-addressed metadata also has a 4 MiB per-document limit. Acquisition
charges discovery, capabilities, key records, and pagination bytes against
that same budget before retention. These untrusted retrieval documents confer
no authority and are unnecessary for offline verification. Each request has a
120-second deadline, and one complete synchronization has a 60-minute budget;
every request uses the smaller of the two remaining allowances. Redirects are
not followed, and encoded response bodies are rejected. Discovery endpoints
must remain under the configured upstream base URL, and the path below it may
contain only unreserved characters in non-empty, non-dot segments. A
percent-encoded separator such as `..%2F` could otherwise be decoded into
another path by an intermediary. The plain-HTTP `localhost` development
exception connects to `127.0.0.1` directly rather than trusting resolver
configuration, matching the listener, which binds `localhost` as `127.0.0.1`.

The checkpoint and its signature come from two mutable `latest` URLs. When the
signature names a different checkpoint, synchronization re-reads the
checkpoint. A changed checkpoint means the upstream published between the
reads, and the pair is fetched again, at most three times. An unchanged
checkpoint is a genuine mismatch and verification rejects it.

Synchronization checks current expiry before fetching content and again
immediately before activation, after retained-proof verification and immutable
resource writes. The final check compares fresh UTC with the already
authenticated expiry and does not repeat cryptographic verification. At an
unchanged sequence, the verifier rejects a checkpoint whose `published_at` or
`expires_at` is earlier than the accepted checkpoint's. A replayed older
renewal therefore cannot shorten established freshness, while identical bytes
remain an idempotent replay. Expired, downgraded, and rolled-back checkpoints
raise `ELWPTRegistryStaleContactError`, a subclass of the registry error. It
marks a stale contact rather than a trust failure, which is what the client
failover rule in the protocol specification needs. Executable contact
selection belongs to [issue #62](https://github.com/frostney/lwpt/issues/62).
Local verification and serving retain exact accepted proof without renewing or
changing its timestamps. `verify` reports `fresh`, `expired`, or
`uninitialized`; an expired retained proof does not authorize acquisition.
The current transfer resumes at verified-object boundaries, not at partial
byte offsets. Unknown signing keys require a complete verified rotation chain
from the immutable root pin.

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
Publication and rotation share one checkpoint-commit routine, which includes
the history preflight. Only the existing atomic current-pointer replacement
activates those files. Recovery removes owned future rotation triplets and
numeric checkpoints; orphan candidate keys are retained but are not served.
Numeric committed checkpoint history remains readable; content-addressed
renewal aliases are served only when selected by the current pointer. The
origin rejects rotation at the shared verifier's 1,000-transition ceiling
before creating a new key.

Origins and mirrors advertise `rotation-chain-v1`. Rotation pages contain at
most 100 ordered items and stay below 1 MiB. Their cursor binds the origin,
`after` sequence, and last item; it is a pagination selector, not authentication.
Mirrors follow bounded pages and verify both signatures of each transition
before trusting its key, requesting its key record, or following any later
item or page. A forged transition therefore costs exactly its own three
documents. Mirrors retain exact key and transition bytes for offline replay.
Invalid pages, missing signatures, or a chain that does not reach the
checkpoint key leave the accepted pointer unchanged. This uses the existing
protocol schemas and canonical Ed25519 implementation without a second
provenance attestation.

## Trust boundaries

The configured origin identity and root pin are the only network trust
inputs. Everything received from an upstream is untrusted until it verifies
against them, and retrieval documents confer no authority.

Local configuration and the data directory are trusted. `registry.toml`,
`state/current.toml`, `state/sync-attempt.toml`, the retained proof, and the
cached objects are all trusted local state. The retained signatures detect
corruption of proof bytes, but they cannot detect a rollback of the state
itself. Restoring an older genuine `state/current.toml` together with its
proof makes that older state the trusted prior. Anyone who can write
`registry.toml` can replace the origin identity and root pin without passing
the `init` reconfiguration guard. Operators must therefore give the data
directory, including `registry.toml`, to one service account: owned by that
account, not writable by any other user, and not placed on shared or
network-writable storage. An origin's private seeds additionally keep their
existing owner-only permissions. Detecting hostile storage rollback would
need an independently protected watermark and is out of scope.

Write paths validate registry directories for links by pathname and then
create and rename files by pathname. A local actor who can rename a directory
inside the data root can win that race and redirect a write. Reads already
open files relative to verified directory handles. The write-side weakness
predates the mirror and is tracked by
[issue #314](https://github.com/frostney/lwpt/issues/314). Until then, the
ownership requirement above is the mitigation.

### Open policy decision: maximum signed lifetime and clock rollback

Freshness depends only on the signed `expires_at` and the local UTC clock.
The protocol's seven-day checkpoint lifetime is a `SHOULD`, not an enforced
limit. A temporarily compromised signing key can therefore issue a checkpoint
that expires in 2099. Any contact can then replay it to a client that has no
newer accepted state, and a mirror accepts it. Separately, moving the system
clock backwards makes an old checkpoint appear unexpired again. This change
does not choose a policy. The decision belongs to the maintainer.

Recommendation: reject, during acquisition, any checkpoint whose
`expires_at - published_at` exceeds seven days plus a small allowance for
clock skew. Record the highest accepted `published_at` per origin in the
state as a clock-rollback floor, and refuse acquisition while the local clock
is earlier than that floor. Locked-proof replay would stay exempt, as it is
from expiry today. The cost is that an origin issuing longer-lived
checkpoints becomes unreadable, and the ceiling would become a protocol
`MUST`.

## Rejected alternatives

- Request-time proxy reads would retain the origin outage dependency and mix
  synchronization with client response deadlines.
- Re-signing or renewing a mirrored checkpoint would replace origin provenance
  with mirror authority and hide staleness.
- Independently replacing the latest checkpoint and signature would expose
  mixed publications. The accepted pointer selects their exact pair.
- Deriving the accepted rotation chain from numbered files in a shared
  directory lets an abandoned attempt's files join a later, unrelated history.
  The state binds the chain by hash instead.
- Verifying the complete retained proof for every request, as the first
  implementation did, made each request, including requests for unknown
  routes, cost a full verification.
