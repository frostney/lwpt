# LWPT Registry Protocol 1

## Executive Summary

- An LWPT registry is an independently operated **origin** or **mirror**. There
  is no global registry, namespace, or service dependency.
- Package identity is `(origin identity, package name, version)`, never the URL
  of the server currently answering a request.
- Immutable package records, snapshots, and archive objects are addressed by
  SHA-256. A short-lived checkpoint signed with Ed25519 identifies the current
  snapshot.
- Origins accept authenticated, atomic publication through the HTTP API.
  Mirrors synchronize the same immutable objects and publish a checkpoint only
  after every referenced object has verified.
- This document specifies the interoperable wire contract. Implementing the
  registry executable, storage engine, command surface, or lifecycle requires
  an implementation ADR in the corresponding implementation issue.

## Status and conformance language

This is version 1 of the LWPT registry protocol. The key words **MUST**,
**MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be
interpreted as described by RFC 2119 and RFC 8174.

The conformance corpus is under
[`tests/fixtures/registry/v1/`](../tests/fixtures/registry/v1/). A server is
protocol-conformant when it can serve the valid corpus with the response
semantics below. A client or mirror is protocol-conformant when it accepts the
valid cases and rejects every invalid case for the stated reason.

## Roles and terminology

**Origin**
: The authority that accepts publications, assigns monotonic snapshot sequence
  numbers, and signs checkpoints.

**Mirror**
: An independently operated, read-only HTTP server that synchronizes immutable
  records and objects from an origin. It presents the origin's identity and
  signatures, not a new package namespace.

**Origin identity**
: The stable URI identifying the authority. It is part of package identity and
  survives a transport or mirror URL change.

**Base URL**
: The HTTPS URL, or permitted localhost development URL, used to contact one
  origin or mirror instance.

**Record**
: Canonical metadata for one published package version.

**Snapshot**
: An immutable, ordered set containing exactly one current package-record hash
  for each package identity.

**Checkpoint**
: A small, expiring document naming the current snapshot and sequence. Its
  detached Ed25519 signature authenticates the origin's current view.

**Object**
: Immutable package archive bytes addressed by SHA-256.

## URI and identity rules

### Permitted transport URLs

A production base URL MUST use `https`. The host MAY be a DNS hostname, an
IPv4 address, or a bracketed IPv6 address.

Plain HTTP is permitted only when the host is the exact, case-insensitive DNS
name `localhost`. `http://127.0.0.1`, `http://[::1]`, private-address ranges,
and arbitrary remote HTTP hosts are not permitted by this protocol. A
non-default port is allowed.

Base URLs MUST NOT contain user information, a query, or a fragment.

Examples:

```text
https://packages.example.com
https://packages.example.com/lwpt
https://192.0.2.10:8443
https://[2001:db8::10]/registry
http://localhost
http://localhost:8080/lwpt
```

### Canonical URI form

Canonical URI comparison uses these rules:

1. Lowercase the scheme and DNS hostname.
2. Remove the default port (`443` for HTTPS, `80` for permitted HTTP).
3. Encode IPv4 in dotted-decimal form and IPv6 according to RFC 5952.
4. Decode percent-encoded unreserved characters and uppercase the hexadecimal
   digits of every remaining percent encoding.
5. Remove dot segments from the path.
6. Remove the trailing slash unless the path is `/`, then represent `/` as an
   empty path.

Servers MUST publish the already-canonical form. Clients MUST reject a document
whose identity or base URL is not canonical rather than silently signing or
hashing a rewritten value.

### Origin identity

At origin initialization, the default origin identity is the canonical initial
base URL. An operator MAY configure an explicit canonical HTTPS URI instead.
Once initialized, the identity is persisted and MUST NOT be recomputed when the
origin moves.

Every signed document and package record contains the origin identity. A mirror
reports the same origin identity but its own base URL. Therefore moving from:

```text
https://packages.example.com
```

to:

```text
https://mirror.example.net/lwpt
```

does not change the identity of an already published package.

### Package identity

A package name is lowercase ASCII matching:

```text
[a-z0-9][a-z0-9._-]{0,127}
```

A version is a canonical SemVer 2.0.0 version without a leading `v`.

The stable identity is:

```text
(origin, name, version)
```

Package names are unique only within an origin. A dependency may name another
origin explicitly; absence of an origin means the record's own origin.

## Canonical TOML profile

Protocol metadata uses a constrained canonical TOML profile so hashes and
signatures operate on exact bytes rather than implementation-dependent
serialization.

Canonical documents:

- are UTF-8 without a byte-order mark;
- use LF line endings and exactly one final LF;
- contain no comments, blank lines, tables, datetimes, floats, or multiline
  strings;
- use only lowercase `snake_case` bare keys;
- use double-quoted basic strings with the shortest valid TOML escape;
- encode booleans as `true` or `false`;
- encode non-negative integers in decimal without a sign or leading zeroes;
- use inline arrays and inline tables only;
- order fields exactly as their schema lists them below;
- sort set-like arrays by the UTF-8 bytes of their canonical element;
- do not contain duplicate keys or unknown fields.

Clients MUST verify canonical form before trusting a hash or signature. An
implementation may parse a non-canonical publication request to produce an
actionable error, but it MUST NOT admit those bytes as a canonical record.

Hashes use:

```text
sha256:<64 lowercase hexadecimal digits>
```

Ed25519 public keys and signatures use:

```text
hex:<lowercase hexadecimal digits>
```

Key identifiers are:

```text
ed25519:<sha256 of the raw 32-byte public key>
```

## Discovery and capabilities

Every server exposes discovery relative to its configured base URL:

```text
GET <base-url>/.well-known/lwpt-registry
```

with media type `application/vnd.lwpt.registry-discovery+toml`.
For example, a registry whose base URL is
`https://packages.example.com/lwpt` exposes discovery at
`https://packages.example.com/lwpt/.well-known/lwpt-registry`. This permits
independent registry instances at different paths on one authority.

Field order and schema:

```toml
schema = "lwpt-registry-discovery-v1"
protocol = 1
origin = "https://packages.example.com"
base_url = "https://mirror.example.net/lwpt"
role = "mirror"
api = "https://mirror.example.net/lwpt/v1"
capabilities = "https://mirror.example.net/lwpt/v1/capabilities"
checkpoint = "https://mirror.example.net/lwpt/v1/checkpoints/latest.toml"
rotations = "https://mirror.example.net/lwpt/v1/rotations"
```

`role` is `origin` or `mirror`. `origin` MUST independently satisfy the
canonical URI and transport rules. `base_url` and every service endpoint URL
MUST satisfy those rules and remain under `base_url`.

The capabilities endpoint returns
`application/vnd.lwpt.registry-capabilities+toml`:

```toml
schema = "lwpt-registry-capabilities-v1"
protocol = 1
hashes = ["sha256"]
signatures = ["ed25519"]
schemas = ["lwpt-registry-capabilities-v1", "lwpt-registry-checkpoint-v1", "lwpt-registry-discovery-v1", "lwpt-registry-error-v1", "lwpt-registry-key-rotation-v1", "lwpt-registry-key-v1", "lwpt-registry-package-v1", "lwpt-registry-page-v1", "lwpt-registry-rotation-page-v1", "lwpt-registry-signature-v1", "lwpt-registry-snapshot-v1"]
features = ["package-list-v1", "publication-v1", "rotation-chain-v1", "snapshot-sync-v1"]
auth_schemes = ["bearer"]
max_page_size = 100
```

Origins advertise `publication-v1`; mirrors MUST NOT. Unknown features may be
ignored. Origins advertising `publication-v1` MUST advertise at least one
authentication scheme. Protocol 1 defines `bearer`; clients send
`Authorization: Bearer <token>`, and an unauthenticated publication request
returns `401` with `WWW-Authenticate: Bearer`. Mirrors use
`auth_schemes = []`. Unknown authentication schemes may be ignored if a common
scheme remains. An unknown required protocol or document schema MUST fail
clearly.

## Immutable resources

Hashed resources MUST be served without `Content-Encoding`; the SHA-256 applies
to the exact response body after HTTP transfer framing is removed. Servers
SHOULD send:

```text
Cache-Control: public, max-age=31536000, immutable
ETag: "<sha256 value>"
```

### Package archive objects

```text
GET /v1/objects/sha256/<hex>
```

returns exact archive bytes with `application/gzip`. The response MUST hash to
the path. A mismatch is corruption and MUST NOT be retried from the same server
without revalidation.

### Package records

```text
GET /v1/records/sha256/<hex>.toml
```

returns `application/vnd.lwpt.registry-package+toml`.

Package-record field order:

```toml
schema = "lwpt-registry-package-v1"
origin = "https://packages.example.com"
name = "example-lib"
version = "1.0.0"
archive = "sha256:..."
archive_size = 261
published_at = "2026-01-01T00:00:00Z"
yanked = false
dependencies = []
```

`published_at` is an RFC 3339 UTC string with whole seconds. Dependency inline
tables have field order `origin`, `name`, `version`; `origin` is omitted only
for the record's own origin. Dependency entries are sorted by origin, name,
then version bytes.

Dependency `version` values use a deliberately restricted canonical SemVer
constraint grammar:

- an exact canonical SemVer version;
- `^` or `~` followed immediately by a canonical SemVer version;
- one or more `<`, `<=`, `>`, or `>=` comparators followed by canonical SemVer
  versions and separated by one ASCII space; or
- alternatives separated by exactly ` || `.

Wildcard, hyphen-range, leading-`v`, redundant-whitespace, and empty
constraints are not protocol 1 canonical forms. This subset is accepted by
LWPT's Semver package while remaining straightforward for independent
implementations. A dependency omitting `origin` uses the record's origin;
otherwise its origin is explicit and canonical.

Records are immutable. Yank status changes through the dedicated lifecycle
operation below, which publishes a new record for the same package identity
and advances the snapshot; it does not rewrite the old record.

### Snapshots

```text
GET /v1/snapshots/sha256/<hex>.toml
```

returns `application/vnd.lwpt.registry-snapshot+toml`.

Snapshot field order:

```toml
schema = "lwpt-registry-snapshot-v1"
origin = "https://packages.example.com"
sequence = 2
published_at = "2026-01-02T00:00:00Z"
previous = "sha256:..."
records = ["sha256:...", "sha256:..."]
```

The first snapshot uses `previous = ""`. Records are sorted by the UTF-8 bytes
of their hash. Each snapshot MUST contain exactly one record for every
`(origin, name, version)` identity visible at that sequence. Publication adds
the new identity; yank and restore replace the prior hash for that identity.
Historical records remain retrievable by hash but MUST NOT coexist with their
replacement in the same snapshot.

A snapshot sequence MUST be exactly one greater than its predecessor. Clients
MUST reject a snapshot whose `previous` value does not match the hash of that
predecessor or whose records contain duplicate package identities.

A client with no locally accepted snapshot walks `previous` hashes backward
from the authenticated checkpoint's snapshot until reaching sequence 1, whose
`previous` is empty. It verifies each hash, origin, sequence decrement, and
identity-uniqueness invariant before accepting the chain. A returning client
may stop at a snapshot hash it already accepted. Historical checkpoint
retention is not required for this bootstrap because the signed current
checkpoint authenticates the content-addressed snapshot chain.

## Checkpoints and signatures

The current checkpoint is available from:

```text
GET /v1/checkpoints/latest.toml
GET /v1/checkpoints/latest.sig.toml
```

Historical checkpoints MAY be retained at:

```text
GET /v1/checkpoints/<sequence>.toml
GET /v1/checkpoints/<sequence>.sig.toml
```

Checkpoint documents use
`application/vnd.lwpt.registry-checkpoint+toml`; detached signatures use
`application/vnd.lwpt.registry-signature+toml`.

Checkpoint field order:

```toml
schema = "lwpt-registry-checkpoint-v1"
origin = "https://packages.example.com"
sequence = 2
snapshot = "sha256:..."
published_at = "2026-01-02T00:00:00Z"
expires_at = "2026-01-09T00:00:00Z"
key_id = "ed25519:..."
```

The signature envelope field order is:

```toml
schema = "lwpt-registry-signature-v1"
algorithm = "ed25519"
key_id = "ed25519:..."
payload = "sha256:<hash of checkpoint bytes>"
signature = "hex:<128 lowercase hexadecimal digits>"
```

The signing input is the ASCII domain separator, including its LF, followed by
the exact checkpoint bytes:

```text
LWPT-REGISTRY-CHECKPOINT-V1\n
```

Clients MUST:

1. Verify canonical checkpoint and signature-envelope bytes.
2. Hash the checkpoint and compare it to `payload`.
3. Require `algorithm = "ed25519"` and the signature envelope's `key_id` to
   equal the checkpoint's `key_id`.
4. Resolve `key_id` from a trusted key or verified rotation chain.
5. Verify the Ed25519 signature over the signing input.
6. Require matching origin identities.
7. Reject an expired checkpoint.
8. Reject a sequence lower than the highest sequence already accepted for that
   origin. At the same sequence, accept only the identical snapshot and
   `key_id`; a different value is checkpoint equivocation. A later
   `published_at`, `expires_at`, and valid signature MAY renew an otherwise
   identical checkpoint.
9. Fetch and hash the snapshot, require its sequence to equal the checkpoint's
   sequence, then validate its predecessor and sequence against the snapshot
   chain.

An origin SHOULD issue checkpoints with a validity window of no more than seven
days. Short expiry limits replay for a client without prior state; persisted
highest-sequence state prevents downgrade for returning clients.

## Trust roots and key rotation

Public key records are available at:

```text
GET /v1/keys/<key-id>.toml
```

Key records use `application/vnd.lwpt.registry-key+toml`.

Field order:

```toml
schema = "lwpt-registry-key-v1"
origin = "https://packages.example.com"
key_id = "ed25519:..."
algorithm = "ed25519"
public_key = "hex:<64 lowercase hexadecimal digits>"
valid_from_sequence = 1
```

The identifier MUST match the SHA-256 of the raw public key. Initial trust is
established out of band by pinning an origin identity and key identifier/public
key pair.

Rotation records are immutable:

```toml
schema = "lwpt-registry-key-rotation-v1"
origin = "https://packages.example.com"
from_key = "ed25519:..."
to_key = "ed25519:..."
to_public_key = "hex:..."
effective_sequence = 2
```

They are served with two detached signature envelopes:

```text
GET /v1/rotations/<effective-sequence>.toml
GET /v1/rotations/<effective-sequence>.old.sig.toml
GET /v1/rotations/<effective-sequence>.new.sig.toml
```

Rotation records use `application/vnd.lwpt.registry-key-rotation+toml`; their
detached signatures use `application/vnd.lwpt.registry-signature+toml`.

The domain separator is:

```text
LWPT-REGISTRY-KEY-ROTATION-V1\n
```

The old-key signature authorizes rotation from an already trusted key and is
REQUIRED. The new-key signature proves possession and is also REQUIRED.
Clients MUST reject a rotation with a mismatched origin, key identifier,
public-key hash, invalid signature, reused/lower effective sequence, or a
`from_key` that is not currently trusted.

After accepting the rotation, checkpoints below `effective_sequence` require
the old key and checkpoints at or above it require the new key. Removing an old
key from active service does not invalidate historical signatures.

### Discovering a rotation chain

Clients discover rotations before authenticating a checkpoint whose `key_id`
is not yet trusted:

```text
GET /v1/rotations?after=<effective-sequence>&limit=<n>&cursor=<opaque>
```

The response is
`application/vnd.lwpt.registry-rotation-page+toml`:

```toml
schema = "lwpt-registry-rotation-page-v1"
origin = "https://packages.example.com"
items = [{ effective_sequence = 2, rotation = "https://packages.example.com/v1/rotations/2.toml", old_signature = "https://packages.example.com/v1/rotations/2.old.sig.toml", new_signature = "https://packages.example.com/v1/rotations/2.new.sig.toml" }]
next_cursor = ""
```

Items are ordered by `effective_sequence`. A client with only its initial trust
root uses `after=0`; thereafter it persists and sends the last accepted
`effective_sequence`. Starting from its pinned key, it fetches and verifies
each dual-signed rotation in order until the checkpoint's key is trusted. The
page itself is discovery data, not a trust root: omitting or reordering entries
can only make synchronization fail because the signed chain will not verify.
Cursors are scoped to the origin and the `after` value.

## Package lookup and pagination

Convenience lookup endpoints are mutable views over an accepted snapshot:

```text
GET /v1/packages?limit=<n>&cursor=<opaque>&snapshot=<sha256>
GET /v1/packages/<name>?limit=<n>&cursor=<opaque>&snapshot=<sha256>
GET /v1/packages/<name>/<version>?snapshot=<sha256>
```

The collection and named-package endpoints return
`application/vnd.lwpt.registry-page+toml`. The exact-version endpoint returns
the current canonical package record bytes with
`application/vnd.lwpt.registry-package+toml`.

The snapshot parameter is REQUIRED after the first collection or named-package
page. The first response pins a snapshot and returns it in the page document.
This prevents concurrent publication from duplicating or omitting entries
between pages. Exact-version lookup also requires a snapshot so yank or restore
cannot change the selected record during a reproducible operation.

Package names sort by UTF-8 bytes; versions sort by SemVer precedence, then
canonical version bytes. Cursors are opaque and MUST be scoped to the origin
and pinned snapshot. `limit` defaults to 50 and MUST NOT exceed the advertised
maximum.

Page field order:

```toml
schema = "lwpt-registry-page-v1"
origin = "https://packages.example.com"
snapshot = "sha256:..."
items = [{ name = "example-lib", version = "1.0.0", record = "sha256:..." }]
next_cursor = ""
```

An empty `next_cursor` means the final page.

## Authenticated publication

Publication is a live, atomic HTTP workflow; an operator does not stop or
restart the registry.

### Upload an archive

```text
PUT /v1/objects/sha256/<hex>
Authorization: <origin-advertised credentials>
Content-Type: application/gzip
```

The origin hashes the complete body before admitting it. An existing identical
object returns `204 No Content`; a new object returns `201 Created`; a mismatch
returns `422 Unprocessable Content`. Partial uploads never become visible.

### Publish a package record

```text
PUT /v1/packages/<name>/<version>
Authorization: <origin-advertised credentials>
Content-Type: application/vnd.lwpt.registry-package+toml
```

The archive object MUST already exist. The origin validates canonical form,
identity, authorization, version ownership, archive hash, and archive size.

Publication is idempotent:

- identical existing record: `204 No Content`;
- newly accepted record and checkpoint: `201 Created`;
- same identity with different immutable content: `409 Conflict`;
- archive absent: `424 Failed Dependency`.

The origin stages the record, snapshot, and checkpoint privately, then exposes
the new checkpoint only after every immutable resource is durable. Readers see
either the previous complete checkpoint or the new complete checkpoint.

### Yank or restore a version

```text
PUT /v1/packages/<name>/<version>/yank
DELETE /v1/packages/<name>/<version>/yank
Authorization: <origin-advertised credentials>
```

`PUT` marks the current version record as yanked; `DELETE` restores it. The
origin verifies package ownership, creates a new immutable record that differs
only in `yanked` and `published_at`, advances the snapshot, and preserves the
old record by hash. Repeating the current state returns `204 No Content`.
Changing state returns `201 Created` after the replacement record, snapshot,
and checkpoint are durable; the response body is the new canonical package
record. Changing archive or dependency content through this endpoint is
forbidden.

Authentication mechanisms are capability-negotiated. Origins MUST support an
HTTP `Authorization` challenge using an advertised scheme and MUST NOT place
credentials in URLs or metadata. Protocol 1's interoperable scheme is Bearer
authentication as defined above. This protocol does not prescribe token
issuance, account, ownership-transfer, or moderation policy.

## Mirror synchronization

Synchronization is pull-based and requires only the read protocol:

1. Fetch discovery and verify the expected origin identity.
2. Fetch the latest checkpoint and inspect its origin, sequence, and `key_id`
   without trusting its contents yet.
3. If `key_id` is unknown, discover and verify the ordered dual-signed rotation
   chain from the already trusted key.
4. Authenticate the checkpoint and enforce expiry, downgrade, and
   equal-sequence equivocation rules.
5. If its sequence is new, fetch and hash its snapshot. Walk the `previous`
   snapshot chain back to sequence 1 or a locally accepted hash, verifying each
   link before accepting the new head.
6. Fetch every missing record and archive object by hash, with bounded
   concurrency and resumable temporary files.
7. Validate record identity, uniqueness, archive size, archive hash, snapshot predecessor,
   and any key rotation.
8. Atomically expose the new checkpoint only after all referenced resources
   are verified and durable.

Repeated synchronization is idempotent. Two mirrors may use different storage
or HTTP server implementations and still serve byte-identical protocol
resources. An origin or mirror MAY offer an authenticated administrative
trigger, but that control surface is not part of the interoperable registry
protocol.

## Errors and HTTP behavior

Errors use `application/vnd.lwpt.registry-error+toml`:

```toml
schema = "lwpt-registry-error-v1"
code = "object_hash_mismatch"
message = "uploaded object does not match its requested sha256"
request_id = "01j00000000000000000000000"
retryable = false
```

Stable codes include:

- `invalid_request` (`400`);
- `authentication_required` (`401`);
- `permission_denied` (`403`);
- `not_found` (`404`);
- `identity_conflict` (`409`);
- `snapshot_conflict` (`409`);
- `failed_dependency` (`424`);
- `unsupported_protocol` (`426`);
- `object_hash_mismatch` (`422`);
- `rate_limited` (`429`);
- `temporary_failure` (`503`).

Conformance clients also report stable local validation reasons:

- `insecure_transport`;
- `non_canonical_document`;
- `signature_payload_mismatch`;
- `signature_invalid`;
- `snapshot_hash_mismatch`;
- `object_hash_mismatch`;
- `duplicate_package_identity`;
- `checkpoint_downgrade`;
- `checkpoint_equivocation`;
- `rotation_chain_invalid`.

Servers SHOULD include `Retry-After` for retryable `429` and `503` responses.
Redirects for discovery, checkpoints, signatures, keys, and publication MUST
remain on a permitted transport URL. Clients MUST revalidate origin identity
after a cross-origin redirect and MUST NOT forward authorization credentials
to a different authority.

## Security requirements

- SHA-256 establishes content identity, not publisher authority. Ed25519
  checkpoints establish authority over a snapshot.
- Clients MUST verify hashes before parsing or extracting archives.
- Archive extraction retains LWPT's existing traversal, symlink, and atomic
  publication protections.
- Origins MUST authenticate publication and authorize package ownership.
- Mirrors MUST not rewrite signed or hashed resources.
- Highest accepted sequence and trusted-key state are stored per origin
  identity, not per mirror URL.
- Error responses and fixtures MUST contain no credentials or private keys.
- Implementations MUST bound response sizes, pagination, concurrent transfers,
  timeouts, and decompressed archive sizes.

## Compatibility

Protocol version and document schema are independently versioned. A server MAY
advertise multiple schema versions. A client MUST fail on an unsupported
required version; it MUST NOT silently reinterpret a v2 document as v1.

Additive capabilities use new feature names. Changing field meaning, canonical
ordering, signature input, identity rules, or required validation creates a new
schema or protocol version.

## Conformance harness schemas

The corpus uses four harness-only schemas that are not served by registries:

- `lwpt-registry-conformance-cases-v1` lists deterministic valid and invalid
  payload evaluations, including required prior state and expected local
  validation reasons. Its `trusted_key_record` binds the pinned origin and key
  identifier to the public key bytes required for initial verification.
- `lwpt-registry-uri-cases-v1` lists permitted and rejected canonical transport
  URIs.
- `lwpt-registry-endpoint-cases-v1` lists every protocol endpoint, request
  fixture, response fixture or media type, successful status, authentication
  requirement, and documented error outcomes.
- `lwpt-registry-outcome-cases-v1` pins deterministic error, idempotency,
  authentication-challenge, and pagination-conflict responses for those
  endpoints.

These schemas use the same canonical TOML profile. Their field order and
complete examples are the files under
[`tests/fixtures/registry/v1/`](../tests/fixtures/registry/v1/).

## Implementation boundary

This specification does not add a registry source kind, subcommand, storage
engine, background daemon, or hosted service to LWPT. Those choices belong to
the implementation issues under
[#29](https://github.com/frostney/lwpt/issues/29).

The implementation PR that chooses the executable interface, command shape,
storage layout, or server lifecycle MUST add an ADR recording the decision.
The ADR is written when that implementation exists, not as part of this
protocol-planning issue.
