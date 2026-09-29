# Registry remote publication

## Status

Accepted on 2026-09-29 by the maintainer, who settled the nine decisions at
the end of this record. Amends [ADR-0043](0043-self-hosted-registry-origin.md), whose
`registry` command family and origin store this extends, and records the
publication decisions the [registry protocol](../registry-spec.md) leaves to
the implementation. Issue [#54](https://github.com/frostney/lwpt/issues/54).

## Context

Issue #54 asks for authenticated publication to an origin that keeps serving
while it publishes. As of `7561079`, the pieces below it already exist:

| Shipped | Where |
| --- | --- |
| GET/HEAD reads of discovery, capabilities, checkpoints (latest, numbered, renewals), signatures, keys, rotation pages and triplets, records, snapshots, and objects | `source/LWPT.Registry.Server.pas:572-781` |
| Every other method answers `405 method_not_allowed` | `Server.pas:605-607` |
| Capabilities advertise `rotation-chain-v1` and `snapshot-sync-v1` with `auth_schemes = []` | `Server.pas:675-676` |
| One request per connection, headers capped at 32 KiB, no request body read, 10-second deadline, 32 connections | `Server.pas:89-92`, `982-1052`; `Server.NetworkFramework.pas:47`, `621-699` |
| In-process `Publish`: lease, verify state, write object and record, build snapshot, commit checkpoint, replace the pointer, then the derived index | `source/LWPT.Registry.Store.pas:2934-3077` |
| Shared checkpoint commit with history preflight | `Store.pas:2811-2843` |
| One `registry-publication` producer lease ([ADR-0038](0038-local-producer-leases.md)) for publication, renewal, rotation, and recovery, taken with a non-blocking `TryAcquire` | `Store.pas:2965`, `2766`, `2863`, `2250` |
| An origin request reads the atomically replaced pointer once, without the generation lock, and verifies it | `Store.pas:2436-2445` |
| A mirror request reads the pointer under the generation lock, so a delayed reader cannot replace a newer cached generation | `LWPT.Registry.Mirror.pas:953-968`; `Store.pas:2545-2570` |
| Test barriers and failure points around checkpoint and activation | `Store.pas:241-247`, `3049-3071` |

There is no remote publication path. `Publish` has only test callers
(`tests/support/Tests.RegistryOrigin.pas:319-335`), and the CLI offers
`init|sync|verify|rotate-key|serve` (`source/lwpt.pas:918`). ADR-0043 also
deferred package-list endpoints to this issue. The current `Publish` has five
properties that a remote API cannot keep:

- The archive arrives as a whole `TBytes` value.
- `dependencies = []` is hard-coded (`Store.pas:2986`).
- The caller's timestamp becomes the snapshot and checkpoint time.
- Idempotency compares record hashes, and those include `published_at`
  (`Store.pas:3018`), so a retry that builds a fresh record conflicts.
- Publication and recovery wipe `tmp/` under the lease (`Store.pas:2969`,
  `2259`), which would delete another client's upload in progress.

The client side is also missing pieces. HTTPClient (0.6.0) has GET, HEAD, and
POST but no PUT or DELETE. It cannot yet trust a private CA
([#302](https://github.com/frostney/lwpt/issues/302)). LWPT has no tar writer
and no zip reader. The installer's gzip decoder (`LWPT.Gzip`) has no
expanded-size bound.

Two sources differ on authentication. The registry epic
([#29](https://github.com/frostney/lwpt/issues/29)) mentions "signed,
replay-resistant requests". The shipped protocol and its conformance corpus
(`tests/fixtures/registry/v1/endpoint-cases.toml`, `outcome-cases.toml`) pin
Bearer authentication, `PUT` for objects and records, `PUT`/`DELETE` for yank,
and their status codes.

## Decision

### Command surface

The `registry` family gains three operations. It remains one top-level
subcommand, as ADR-0043 and ADR-0045 established, so no new top-level
vocabulary is added. This ADR is the approval the frozen-surface rule
requires.

```text
lwpt registry publish <archive.tar.gz|archive.zip> --origin <base-url>
    --key-id <ed25519:...> --public-key <hex:...> [--token-env <NAME>] [--silent]
lwpt registry issue-token [--data-dir <path>] --packages <pattern[,pattern...]>
    [--actions publish[,yank]] [--expires-days <n>] [--label <text>] [--silent]
lwpt registry revoke-token [--data-dir <path>] --token-id <id> [--silent]
```

- `publish` is a client. It reads no `lwpt.toml`, needs no project, and writes
  nothing to disk. `--origin` is the origin's contact base URL. `--key-id`
  and `--public-key` reuse the mirror's pin options and are the trust root for
  post-commit verification. `--token-env` names the environment variable that
  holds the token and defaults to `LWPT_REGISTRY_TOKEN`, derived from
  `PROJECT_NAME`. This follows the `--tls-password-env` precedent. A token is
  never accepted as an option value. On success, stdout gets one line:
  `published <name>@<version> to <origin> at sequence <n> (archive <hash>,
  record <hash>)`,
  or `already published …` for an idempotent retry. `--silent` keeps only that
  line. Failures exit 1 with `registry: <code>: <local message>` on stderr.
- `issue-token` and `revoke-token` are operator-local, like `rotate-key`. They
  run against the data directory while `serve` keeps running. `issue-token`
  prints the token once, as its only stdout line. On an origin, `registry
  verify` also lists token metadata (ID, label, patterns, actions, expiry,
  revocation) and never secrets.
- Each operation accepts only its own options, and any other option is an
  `invalid_configuration` error, as today. The shared option list in
  `lwpt.pas` gains `origin`, `token-env`, `packages`, `actions`,
  `expires-days`, `label`, and `token-id`. Each description names its
  operation. The usage string becomes
  `<init|sync|verify|rotate-key|publish|issue-token|revoke-token|serve>`, and
  `lwpt agents` regenerates the AGENTS.md reference from that registry.
  `lwpt agents --check` gates the change.

### Wire protocol

The server implements the endpoints, status codes, and media types already
pinned by the specification and the corpus, as amended under "Rule amendments". It advertises `package-list-v1`
on origins and mirrors, because pages derive from the captured read view.
Origins additionally advertise `publication-v1` with `auth_schemes =
["bearer"]` while at least one active token exists. Otherwise they stay
read-only, exactly as today.

- **Package reads.** `GET /v1/packages`, `/v1/packages/<name>`, and
  `/v1/packages/<name>/<version>` are computed from the snapshot named by the
  `snapshot` parameter, or from the captured head on a first page. That
  snapshot must be in accepted history. Cursors bind the snapshot. A mismatch
  returns `409 snapshot_conflict`, and `limit` is at most 100.
- **Queries.** Queries are accepted on two kinds of route. `/v1/rotations`
  keeps its existing `after`, `limit`, and `cursor` parameters, which
  rotated-key discovery needs. The package routes above accept `limit`,
  `cursor`, and `snapshot`, and they decode percent-encoding strictly. A query
  on any other route is still `400 invalid_request_target`.
- **Upload.** `PUT /v1/objects/sha256/<hex>` streams to
  `incoming/<upload-id>.part` while hashing, then moves to
  `incoming/sha256/<hex>`. A new object returns `201`. An object already
  present under `incoming/` or `objects/` returns `204`, and a digest mismatch
  returns `422 object_hash_mismatch`. Nothing under `incoming/` is served,
  because serving is membership-based (ADR-0045). Uploads use `incoming/`,
  not `tmp/`, so a concurrent commit or recovery cannot wipe them. Ownership
  and accounting are defined under "Upload staging" below.
- **Publish.** `PUT /v1/packages/<name>/<version>` carries a canonical package
  record whose name and version equal the path and whose origin equals the
  configured identity, with `yanked = false`. A record with `yanked = true`
  is `400 invalid_request`, because yanking goes only through the lifecycle
  endpoints. When a record for that identity is already active, the server compares **content identity**: `archive`,
  `archive_size`, and `dependencies`, but not `published_at` or `yanked`.
  Equal content returns `204` with the active record, even if it is yanked.
  Different content returns `409 identity_conflict`. For a new version, the
  server requires `published_at` to be within five minutes of its own clock,
  and the archive object must be incoming or committed with the stated size.
  If it is not, the server returns `424 failed_dependency`.
- **Yank/restore.** `PUT` and `DELETE` on `/v1/packages/<name>/<version>/yank`
  work as specified and use the same commit path.
- **Responses.**
  - Object uploads answer `201` or `204` with an empty body and
    `ETag: "sha256:<hex>"`, and carry no `Location`. An object is not yet a
    package record, and one object may serve several records.
  - Record publication, yank, and restore answer `201` or `204` with
    `Location: <base>/v1/records/sha256/<hex>.toml`. The location names the
    record active for that identity once the request completes. A `201`
    from yank or restore also returns that record as its body, as the spec
    requires.
  - Errors use `lwpt-registry-error-v1` with a per-request `request_id`.
    Their `message` is fixed server text and never echoes request content.

| Status | Code | Cause |
| --- | --- | --- |
| 400 | `invalid_request` | Malformed or non-canonical record, path mismatch, clock skew, missing `Content-Length`, any `Transfer-Encoding` or `Content-Encoding` |
| 401 | `authentication_required` | Missing, malformed, unknown, revoked, expired, or wrong token (one indistinguishable answer, `WWW-Authenticate: Bearer`) |
| 403 | `permission_denied` | Token lacks the action or a pattern matching the package |
| 404 | `not_found` | Yank or restore of an absent version |
| 405 | `method_not_allowed` | Mutation sent to a mirror or a read-only origin |
| 409 | `identity_conflict` | Same identity, different content |
| 413 | `payload_too_large` | Declared length over the limit, rejected before the body is read |
| 422 | `object_hash_mismatch` | Upload bytes do not hash to the path |
| 424 | `failed_dependency` | Archive object absent or of a different size |
| 429 | `rate_limited` | Rate bound exceeded (`Retry-After`) |
| 503 | `temporary_failure` | Lease busy after its wait, body concurrency full, or server clock behind the active checkpoint (`Retry-After`) |
| 507 | `storage_budget_exceeded` | Unreferenced uploads would exceed their budget |

These bounds are fixed, so an unchanged origin configuration schema stays
unchanged:

- An archive may be at most 256 MiB. This equals the mirror
  (`LWPT.Registry.Mirror.pas:18`) and installer (`LWPT.Install.pas:165`)
  limits, so every published archive can be mirrored and installed.
- A record body may be at most 64 KiB, and headers stay at 32 KiB.
- Uploads not yet committed, including those in progress, may total at most
  1 GiB across at most 1,000 entries (see "Upload staging").
- At most two request bodies may be in flight. The body deadline is 30 seconds
  plus one second per MiB declared.
- Each token may make 60 mutating requests per minute. Each peer address may
  make 20 failed authentications per minute.
- A commit waits up to 5 seconds for the lease.

Rate state is in memory and resets on restart. The server applies
authentication, length, and concurrency checks after reading the headers and
before reading the body.

### Upload staging

Uploads run outside the publication lease. Their ownership and accounting
therefore rest on operating-system guards and on the directory itself, not
on memory in one process.

- **Accounting guard.** The `registry-incoming` producer lease (ADR-0038)
  guards the whole `incoming/` namespace. Every accounting-relevant
  transition happens while that lease is held:
  - creating a `.part` file, which is a reservation;
  - renaming a `.part` to `incoming/sha256/<hex>` on completion;
  - deleting a `.part` or a completed entry, whether by its owner,
    reclamation, or one-hour expiry;
  - moving a completed entry into `objects/`.

  An admission scan therefore sees a fixed namespace. No charged file can
  move from an unscanned directory into one already scanned, so no charge is
  missed. The lease is held only for the scan plus one namespace operation.
  Hashing, reading the body, and verifying the commit all happen outside it.
- **Lock ordering.** Only three acquisitions ever wait, and each wait is
  bounded:
  - the publication lease, up to 5 seconds, and never while any other
    registry lease is held;
  - `registry-incoming`, up to 2 seconds, possibly while holding the
    publication lease or the caller's own upload lease;
  - an upload's own lease, taken before its `.part` exists and so before any
    other lease is held.

  The resulting order is publication lease, then upload lease, then
  `registry-incoming`. Another upload's lease is only ever tried without
  waiting, including under `registry-incoming` during reclamation, so a
  held lease just means "live, skip it". No cycle can form. Every bounded
  wait that times out answers `503 temporary_failure` with `Retry-After`,
  which the client retries. What it leaves behind depends on the caller:
  - **Admission** holds nothing when it times out, so it leaves no
    reservation behind.
  - **An upload owner** already owns a charged `.part`. It can time out
    while completing, or while deleting its `.part` after a failure,
    cancellation, or digest mismatch. The owner cannot remove that file
    without the guard, so it leaves the `.part` in place, still counted,
    and releases its own upload lease. The file is then reclaimable, and
    the reclamation path below deletes it and frees the charge. The
    client's retry uploads again under a new upload ID.
  - **A commit** times out before it moves anything, so it leaves
    `incoming/` and `objects/` unchanged and releases the publication
    lease.
- **Reservation.** After the headers pass authentication and the length
  check, admission takes `registry-incoming`. It sums the lengths of every
  file under `incoming/`. When the declared `Content-Length` still fits the
  1 GiB and 1,000-entry budget, it creates `incoming/<upload-id>.part` at
  exactly that length and releases the lease. The upload ID is 128 random
  bits. A file's length is its reservation, so an in-progress upload counts
  in full from admission. Concurrent admissions, whether in one process or
  several, are serialized and cannot overcommit. An upload that does not fit
  gets `507 storage_budget_exceeded` before any body byte is read.
- **Ownership.** Each upload holds a per-upload producer lease keyed by its
  upload ID from creation to completion. Liveness is the OS guard, so a
  `.part` file is never deleted because of its age. The owner deletes its own
  `.part`, under `registry-incoming`, on failure, cancellation, or digest
  mismatch. Deleting the file releases the reservation.
- **Reclaiming.** An upload admission or a publication-lease holder, while
  holding `registry-incoming`, may delete another upload's `.part` only after
  it acquires that upload's lease without waiting. Acquiring it proves that
  no live request owns the file: either the owning process exited, or its
  owner gave the file up after a guard timeout. Every admission and every
  publication-lease holder runs this sweep, so an abandoned reservation is
  freed at the next such operation, not after some age.
- **Completion.** A verified upload takes `registry-incoming`. If
  `incoming/sha256/<hex>` or `objects/sha256/<hex>` already exists, it
  deletes its `.part` and answers `204`. Otherwise it renames the `.part` to
  `incoming/sha256/<hex>` and answers `201`. The renamed file keeps its length
  and therefore its charge. Completed entries are deleted, or moved into
  `objects/` by a commit, only by a publication-lease holder that also holds
  `registry-incoming` for that one operation. That holder rehashes the entry
  before taking the lease. A commit can therefore never lose its object to
  cleanup. A record that arrives after the one-hour expiry gets `424`, and
  the client uploads again once.
- **Failed activation.** The commit moves the object into `objects/` under the
  publication lease and `registry-incoming`, before activation. If activation then does not happen,
  the object stays in `objects/` without a reference. It is not served,
  because serving is membership-based. It no longer counts against the
  incoming budget. A re-upload of the same bytes answers `204`, and the retried
  commit references the object in place. Each failed commit leaves at most one
  such object, and ADR-0043's rule that objects accumulate until a retention
  design exists covers it. The current `Publish` already leaves the same
  residue on `identity_conflict`.

### Commit and atomicity

`Publish` is split into two steps, reusing the existing machinery:

1. Receiving an upload runs without the lease.
2. Committing a version runs under `registry-publication`. The server reads
   and verifies the current state and repeats the idempotency check, because
   another client may have committed meanwhile. It rehashes the incoming
   object and moves it into `objects/`, then writes the record. It builds the
   snapshot and calls `CommitCheckpoint`, which includes the history
   preflight. `AtomicWriteBytes` replaces `state/current.toml`, and the
   derived index is updated after that.

The snapshot and checkpoint take the server's clock, never the client's. A
server clock earlier than the active checkpoint's `published_at` refuses to
commit.

Readers need no new mechanism. An origin request reads `state/current.toml`
once (`CaptureReadView`, `Store.pas:2436-2445`) and does not take the
generation lock. Atomic replacement gives it either the complete old
document or the complete new one. Everything that document names is
immutable and verified before it is served. Readers therefore see the old or
the new signed head and never a mix. That existing origin behavior stays
unchanged. The one read-side addition is the per-head package-list index. It
follows the mirror pattern: the index is built under the generation lock and
keyed by the pointer bytes (`LWPT.Registry.Mirror.pas:953-968`), so a delayed
request cannot install a stale index.

Activation failure follows the code as it stands:

- A failure before the pointer is replaced, including the `checkpoint`
  failure point (`Store.pas:3049-3051`), leaves the old head served. Numeric
  checkpoints ahead of the pointer are not proof, and recovery removes them.
  A retry commits at the same next sequence.
- A failure after the pointer is replaced, such as the `activation` failure
  point, which follows the replacement (`Store.pas:3068-3071`), leaves the
  new head committed and served. Only the derived index is missing or stale.
  Recovery rebuilds it from the active snapshot, as the existing test expects
  (`LWPT.Registry.Store.Test.pas:800-826`). The request answers
  `503 temporary_failure`, and the retry returns `204` with the `Location` of
  the committed record.

A `201` is sent only after the pointer is replaced, so a lost `201` also
becomes a `204` on retry.
Until [#62](https://github.com/frostney/lwpt/issues/62) defines registry
dependency sources, records keep `dependencies = []` (decision 4). The commit
path still validates any canonical dependency list, so #62 needs no store
change. Commits are serialized: a second publisher waits for the lease or
gets a retryable `503`.

### Credentials and scope

A token is
`<PROGRAM_NAME>_rt1_<token-id>_<secret>`. The token ID is 32 lowercase hex
digits (128 random bits, not secret), and the secret is 43 base64url
characters (256 random bits). The fixed prefix lets secret scanners find
leaked tokens. `issue-token` writes `auth/tokens/<token-id>.toml`
(`lwpt-registry-token-v1`). The file holds the ID, label, sorted package
patterns, sorted actions, `created_at`, `expires_at`, `revoked_at`, and
`secret_hash = "sha256:…"`. It is created through the owner-only private-file
path used for seeds (`AtomicCreatePrivateBytes`, `Store.pas:361`). A fast hash
is enough because the secret is 256 random bits. The comparison runs in
constant time.

- Patterns are an exact protocol package name, a protocol-name prefix
  followed by one trailing `*`, or `*` alone. Actions are `publish` (upload
  and record) and `yank` (yank and restore). An upload needs `publish` on any
  pattern, because objects are unscoped until a record references them.
- Every token expires. `--expires-days` defaults to 90 and accepts 1 to 365.
  No non-expiring form exists (decision 2).
- The server reads the token file on every mutating request and caches
  nothing. Revocation (`revoke-token` atomically sets `revoked_at` and keeps
  the file) and expiry therefore take effect on the next request without a
  restart. Rotation means issuing a new token, switching the CI secret, and
  revoking the old one. Validity periods may overlap. At most 1,000 active
  tokens are supported.
- The client reads the named environment variable once, after validating the
  transport and the archive, and wipes its buffer after the last request. A missing or
  malformed token fails locally with `credential_missing` or
  `credential_invalid`, naming the variable but never the value. Tokens are
  never read from or written to `lwpt.toml`, `lwpt.lock`, `.lwpt/`, logs, or
  diagnostics.
- **Client diagnostics are generated locally.** An origin or proxy can reflect
  the bearer token in any printable field, and stripping control characters or
  truncating does not remove it. `publish` therefore never prints a server
  `message` or status text. It prints its own text, with only these
  response-derived values:
  - a `code` that matches `[a-z][a-z0-9_]{0,63}` and is one this ADR or the
    protocol lists, and otherwise `unrecognized_error`;
  - a `request_id` that matches `[0-9a-z]{1,64}`;
  - hashes parsed from `Location` or `ETag` that match the protocol hash
    grammar;
  - the origin identity only after the pinned key has authenticated it.

  As a second line of defense, every response-derived value is checked before
  it is printed, and so is every HTTPClient exception message. This covers
  the identity, every header value, and every TOML field. Any occurrence of
  the full token or its secret part is replaced with `[redacted]`.
- **Server diagnostics are generated locally too.** Server error `message`
  fields and stderr lines are fixed text plus validated metadata. They never
  include the raw request target, headers, or body.

### Audit records

Every mutating request writes one immutable file,
`audit/<yyyy>/<mm>/<dd>/<received-at>-<request-id>.toml`
(`lwpt-registry-audit-v1`), through the atomic helpers. The file records:

- the request ID, receive and completion times, and the socket peer address
  (forwarded headers are not trusted);
- the method and the **validated** route: its template (for example
  `/v1/packages/{name}/{version}/yank`) plus parameters that have already
  passed the name, version, or hash grammar. It is never the raw request
  target. A target that fails routing is recorded as `route = "invalid"`,
  so a token misplaced in a path or query is never written;
- the verified token ID, or empty;
- the action, name, version, and archive and record hashes;
- the status and code;
- the resulting sequence and checkpoint hash;
- for a 401, the internal cause (unknown, revoked, expired, mismatch), which
  the client never sees.

It never contains the `Authorization` header, a secret, a secret hash, or a
request body. Rate-limited failures are aggregated to one record per peer per
minute. Audit records are not served, are not part of any snapshot, and are
never pruned by LWPT. Operators archive them with ordinary tools. If an audit
write fails after activation, the server logs it to stderr with the request
ID and does not undo the publication.

### Transport security

- The client canonicalizes `--origin` using the protocol's URI rules. It
  requires `https`. Plain `http` is allowed only for the exact host
  `localhost`, which it dials at `127.0.0.1` through `ConnectAddress` as the
  mirror does (`LWPT.Registry.Mirror.pas:240-307`). Anything else fails with
  `insecure_transport` before any connection is made or the token is read.
- Requests go through HTTPClient with verified TLS (ADR-0016) and no insecure
  mode. `AllowedHosts` contains only the origin host, `RequireHTTPS` is set
  (except for localhost), and `MaximumRedirects = 0`. Any `3xx` fails with
  `unexpected_redirect`, so the credential is never sent to a second
  authority. HTTPClient connects over IPv4 only.
- The destination comes only from the invoking user's command line. It never
  comes from project files, so ADR-0048's transitive-manifest threat does not
  apply. Private addresses are allowed (decision 6).
- HTTPClient gains PUT and DELETE with byte bodies in a package minor
  release, with the package's own tests, including the Windows mock server.
  Private-CA trust comes from #302.
- The server's TLS lifecycle is unchanged. Request-body reading is added to
  all three transports: the plain loop, the TLS feed/drain loop, and
  Network.framework.

### Post-publish verification

Before its first upload, `publish` fetches discovery and capabilities. It
requires role `origin`, `publication-v1`, and `bearer`, then verifies the
latest checkpoint against the pin with the shared acquisition verifier (the
"before" head). After a `201` or `204`, it verifies the latest checkpoint
again. It then requires:

- **Consistency.** The new head's snapshot chain reaches the before head.
- **Inclusion.** The new snapshot holds the `Location` record, and its
  identity and content match.

It exits 0 only when both hold. Expired, downgraded, equivocating, or
malformed proofs fail with the verifier's stable reasons. The client persists
no state, so consistency holds within one invocation. Cross-invocation
history belongs to the consumer trust store in
[#62](https://github.com/frostney/lwpt/issues/62). The client retries only
`429`, `503`, and transport failures on idempotent requests: at most five
attempts, with exponential backoff capped by `Retry-After` and 60 seconds.

### Archive contract

The registry, mirrors, the protocol (`application/gzip` objects), and
`lwpt install` keep exactly one archive format: gzip tar. `publish` chooses
its input path from the leading bytes, not the file extension. Input starting
with `1f 8b` is a tar.gz. Input starting with `PK\x03\x04` or `PK\x05\x06`
is a zip. Anything else fails with `unsupported_archive`.

- **tar.gz** is uploaded exactly as given. `publish` scans it without
  extracting it. It applies the installer's traversal and link rules
  (`LWPT.Install.pas:1301-1373`) and component limit (`:1485`, `:1540-1553`), plus the
  1 GiB expanded bound defined below, which the installer's decoder lacks.
  The archive must have exactly one top-level directory, which the installer
  strips (`:1221-1233`). That directory must contain `lwpt.toml`, whose
  `[package] name` and `version` are the protocol-valid publication identity.
  Exactly one entry may reach that manifest's extraction destination, and
  it must be a regular file. A second entry that expands to the same path
  (such as `./lwpt.toml`), a link or directory there, or a spelling that a
  case-insensitive or Windows file system resolves to it (ASCII case, a
  trailing `.` or space, an NTFS stream suffix, or the `lwpt~` 8.3 short
  name) is refused, because installing it would replace the identity that
  was inspected. Zip normalization refuses the same spellings.
- **zip** is normalized on the client into one canonical tar.gz, described
  in the next section. Only that tar.gz is uploaded, stored, hashed, and
  served.

For both formats, the identity checks and decision 4's dependency rule run
on the resulting tree. A `[dependencies]` declaration fails with
`unsupported_dependencies`. All archive validation finishes before the
token is read or any connection is made. The server never decompresses archives. It binds only
the hash and size.

### Zip normalization

Normalization is a pure function of the zip bytes and the normalizer
version. It uses no clock, locale, file-system metadata, environment, or
network, and it writes no file: the input and output live in memory within
the bounds below. It never touches project state. A failure happens before
the token is read or any connection is made.

**Container rules.** These rules keep every zip reader seeing the same
entries, so nothing can hide in the archive:

- The end-of-central-directory record must end exactly at the end of the
  input, and its comment length must account for every trailing byte. The
  comment is ignored.
- Every disk-number field must be 0, and the entries on this disk must equal
  the total. Multi-disk and split archives are rejected.
- The central directory must end exactly where the end record begins. The
  first local header must be at offset 0. The local records must fill
  `[0, central-directory offset)` in central-directory order with no gaps,
  overlaps, or prepended data, so self-extracting stubs and overlapping-entry
  bombs are rejected.
- Each local header must repeat its central entry's name bytes, method, and
  flags. It must also repeat the CRC and sizes, unless data-descriptor mode
  is used.
- **ZIP64 is rejected**: its records, locator, `0xFFFF` or `0xFFFFFFFF`
  sentinels, and extra field `0x0001`. Every bound below fits the classic
  16- and 32-bit fields. Rejecting ZIP64 removes a second set of sizes that
  could disagree with the first.
- **Data descriptors are accepted** (flag bit 3). macOS Archive Utility and
  Java write them, and they are safe under these rules. The central
  directory's CRC and sizes are authoritative. The local CRC and sizes must
  be zero or equal to the central ones. The 12-byte descriptor, or 16 bytes
  with its optional signature, must follow the data, match the central
  values, and count toward the no-gap fill. The 32-bit form is the only form
  accepted.
- The allowed methods are 0 (stored, where the compressed size must equal
  the uncompressed size) and 8 (deflate). The allowed flags are bits 1 and 2
  (deflate options), 3, and 11 (UTF-8). **Encryption is rejected**: flag
  bits 0 and 6, AES method 99, and every other method or flag. Extra fields
  must parse within their declared lengths and are otherwise ignored.
- **Payload decoding** works on exactly the compressed slice the central
  directory declares, from the data offset through the compressed size.
  - Method 8 is inflated with `zinflate`. The stream must reach
    `Z_STREAM_END` exactly when the slice is consumed (`avail_in = 0`) and
    the output reaches the declared uncompressed size. Four cases are
    rejected: a stream that ends early or is truncated (the slice is
    exhausted before `Z_STREAM_END`); compressed bytes left after
    `Z_STREAM_END`; output short of the declared size; and output past it,
    where inflation stops one byte past the size.
  - Method 0 is never passed to the inflater. It copies exactly the declared
    bytes, and the compressed size must equal the uncompressed size.
  - Both methods then require the CRC-32 to match.

**Entry rules.** These are the tar preflight's rules applied to each name,
followed by rules that the canonical form needs:

- The name must be strict UTF-8 with no control characters. `\` is read as
  `/`, as the installer does.
- The same rules reject empty, absolute (`/`, `\`, or a drive letter), and
  `..` paths, and any component longer than 255 bytes.
- `.` and empty components are rejected as well. The single terminal `/`
  that marks a directory entry is not a component. Consecutive slashes, as
  in `a//`, and `/` on its own are rejected.
- Only regular files and directories are allowed. A directory name ends
  with `/`, has size 0, and has CRC 0.

**Namespace rules.** These are checked once over the whole normalized tree,
after the package-root mapping below. The tree holds every explicit entry and
every parent directory that an entry implies, because the tar writer emits
those parents too:

- No path may be both a file and a directory, whether explicit or implied. A
  file `a` next to `a/b` is rejected, and so is a file `a` next to an entry
  `a/`.
- No file may be an ancestor of another entry.
- Duplicate explicit names are rejected. An explicit directory entry that
  matches an implied parent is accepted, because the paths are
  byte-identical.
- No two distinct paths in the tree may be equal after ASCII case folding.
  This includes implied directories, so `A/x` and `a/y` collide through
  `A/` and `a/`. The rule holds on every platform, so a package extracts the
  same way on case-insensitive Windows and macOS.
- When the creating host is Unix (3), the file type in the upper 16 bits of
  the external attributes must be regular, directory, or unset. Symlinks,
  devices, FIFOs, and sockets are rejected. When the host is MS-DOS (0), the
  directory bit must agree with the trailing slash, and volume labels are
  rejected. External attributes from other hosts are ignored.

**Package root.** The package root is the zip root when it contains
`lwpt.toml`. Otherwise it is the zip's single top-level directory, and that
directory must contain `lwpt.toml`. Any other layout is rejected. Output paths
are `<name>-<version>/<path below the root>`, using the manifest identity.
Every path must fit ustar's split at a `/` into a prefix of at most 155 bytes
and a name of at most 100 bytes. At install time, the installer still checks
the platform path limits (`:1470-1538`).

**Canonical tar.gz.** The output is POSIX ustar with no GNU or pax
extensions:

- Every directory is emitted explicitly, including the root and parents the
  zip only implies. Entries are sorted by the UTF-8 bytes of their path, and
  a directory path ends with `/`.
- Directories get mode `0755`. A file gets `0755` when the host is Unix and
  its mode has any execute bit set, and `0644` otherwise.
- uid and gid are 0. uname, gname, linkname, and the device fields are
  empty. mtime is 0. The magic is `ustar\0` with version `00`, and the
  checksum is standard.
- The archive ends with two zero blocks and is padded to a multiple of
  10,240 bytes.
- The gzip layer has one member. Its header bytes are `1f 8b 08`, then FLG
  0, MTIME 0, XFL 0, and OS 255. It is raw deflate from paszlib `zdeflate`
  at level 9, window bits −15, memory level 8, and the default strategy.
  Input is fed in fixed 64 KiB chunks with `Z_NO_FLUSH`, followed by one
  `Z_FINISH`. CRC-32 and ISIZE close the member.

Zip timestamps, comments, and extra fields are dropped. Entry order, entry
compression, and timestamps therefore do not affect the output. Two zips that
hold the same names, bytes, and execute bits produce the same tar.gz.

**Bounds** (fixed; each fails with `archive_limit_exceeded`):

- The zip may be at most 256 MiB.
- It may have at most 10,000 central entries. The central-directory size
  must be at least 46 bytes per declared entry, and this is checked before
  anything is allocated.
- The declared uncompressed sizes may total at most 1 GiB. This sum is
  checked before anything is inflated, and each entry's actual size is
  enforced as it inflates.
- The canonical tar.gz must be at most 256 MiB. Generation stops once the
  output passes that size.
- `lwpt.toml` may be at most 256 KiB and parse to at most 10,000 TOML
  nodes. Its declared size is checked before it is decoded or buffered, in
  both the zip and tar.gz paths.
- A path longer than any ustar path could hold (256 bytes in the output,
  so 254 below the package root) is refused with `invalid_archive` before
  any implied parent is built. The distinct paths of the normalized tree, explicit and
  implied, may total at most 16 MiB; the check runs as the tree is built.

Peak memory is about the input size plus the output size plus fixed buffers.

**Determinism is a compatibility contract.** Every retry of the same zip must
yield the same tar.gz bytes, including on another platform or another LWPT
version, or it would conflict with its own first publication. Golden
fixtures pin the output hash on every release platform. Any change to the
writer or to paszlib's deflate output fails those fixtures. Such a change is
allowed only as a new, documented normalizer version.

**Implementation constraint.** FPC's `zipper` is not built by LWPT's cross
toolchain, so the zip reader is written in-tree on `zinflate` and `crc`, as
`LWPT.Gzip` already is. The cross toolchain compiles paszlib's `zstream.pp`
(`toolchain.yml:377-384`), and that unit's implementation uses `zdeflate`
(`zstream.pp:116` in FPC 3.2.2). `zdeflate` is therefore already built for every
target. The implementation PR adds it to the `require_unit` guards in
`ci.yml` and `release.yml`, which assert only `zstream` today. The
deterministic tar writer is written once. The directory-packing follow-up
(decision 3) reuses it.

### Rule amendments

The implementation PR applies these amendments; this ADR does not.

- **AGENTS.md, "Network operations are explicit".** Add: "`lwpt registry
  publish` uploads to the origin named on its command line and is the only
  toolkit command that sends credentials
  ([ADR-0049](./docs/adr/0049-registry-remote-publication.md)).
  `lwpt registry serve` also accepts authenticated publication on origins
  with an active token."
- **AGENTS.md, subcommand list.** The list becomes
  `registry init|sync|verify|rotate-key|publish|issue-token|revoke-token|serve`.
  This also restores `rotate-key`, which the hard constraint currently omits.
- **Registry specification.**
  - Define "different immutable content" as content identity, and state that
    the server assigns snapshot and checkpoint time.
  - Add the `published_at` skew window, the `Location` header, the no-redirect
    rule for publication, and the archive layout.
  - List `method_not_allowed` (405), `payload_too_large` (413), and
    `storage_budget_exceeded` (507).
  - Replace ADR-0043's "package lists and remote publication remain #54".
- **Conformance corpus** (`tests/fixtures/registry/v1/outcome-cases.toml`,
  with the matching `endpoint-cases.toml` entries). The corpus changes with
  the spec, because the new identity rules change what some existing cases
  mean.
  - `package-identity-conflict` currently sends
    `records/ac8180e8….toml`. That record differs from the active 1.1.0 record
    only in `yanked` and `published_at`, so under this ADR it is not a
    content conflict. The case moves to a new request fixture for
    `example-lib` 1.1.0 with a different `archive` and `archive_size`, which
    is genuinely different content, and still expects
    `409 identity_conflict`.
  - A new case, `publish-yanked-record-rejected`, sends that same
    `ac8180e8…` record and expects `400 invalid_request`: yanking through
    publication is forbidden.
  - A new case, `publish-timestamp-only-retry`, sends
    `records/7802b04a….toml`. It matches the active `3ed9d3d8…` record
    except for `published_at`, and it expects `204` with the `Location` of
    the active record.
  - Conformance runs of new-version publication (`publish-package-created`)
    set the registry test clock (`SetRegistryClockForTesting`) to the
    fixture's `published_at`, so the five-minute skew rule does not depend
    on when the test runs.

### Test plan

| Acceptance criterion | Evidence |
| --- | --- |
| A CI client publishes to a running origin | E2E: `registry init`, then `serve`, then `issue-token`, then `publish` over localhost HTTP. The server PID stays the same and served reads show the new head. |
| Readers see the old or new head | E2E: a reader loop verifies every checkpoint, signature, and snapshot with the shared verifier while `publish` holds the publication barrier. Store test: the `checkpoint` failure point leaves the old head, and a retry commits at the same next sequence. The `activation` failure point, which comes after the pointer replacement, leaves the new head served and the index missing. Recovery rebuilds the index, and a retry returns `204` (extending `LWPT.Registry.Store.Test.pas:800-826`). |
| Crash mid-publish | E2E: kill `serve` at the barrier, restart, get the old head, retry, and get `201` at the same next sequence. Kill during an upload: the `.part` file is reclaimed only after its upload lease is free. A live upload's `.part` survives a concurrent admission and commit. |
| Guard timeout leaves a reclaimable reservation | A `REGISTRY_TESTING` seam holds `registry-incoming` past the 2-second wait. A completing upload answers `503` with `Retry-After`, leaves its `.part` counted at full length, and releases its upload lease. The same holds for an owner deleting after a digest mismatch. Once the guard is free, the next admission reclaims the `.part`, frees its charge, and fits an upload that did not fit before. The client's retry, under a new upload ID, returns `201`. A timed-out admission leaves no file behind. A timed-out commit leaves `incoming/`, `objects/`, and the served head unchanged. |
| Completion versus admission race | A `REGISTRY_TESTING` barrier pauses an admission scan after `incoming/sha256/` and before the root. An upload that finishes meanwhile blocks on `registry-incoming` until the scan releases it. Starting from exactly 1 GiB reserved (three completed 256 MiB objects plus one 256 MiB upload), the paused admission of another 256 MiB gets `507`, and reservations never exceed 1 GiB. Reclamation, expiry, and the move into `objects/` get the same barrier test. Admission, completion, and a commit running together finish within their bounded waits without deadlock. |
| Upload accounting | Two admissions that would together exceed 1 GiB: exactly one proceeds and the other gets `507`. An in-progress upload counts at its declared length. A digest mismatch, an abort, or an existing object releases its reservation. An object moved into `objects/` before a failed activation is unserved, answers `204` on re-upload, and is referenced by the retried commit. |
| Identical retry succeeds | Same archive, a fresh `published_at`, and a lost-response retry each return `204` with an unchanged sequence and exit 0. |
| Conflicting content rejected | A different archive for an existing version returns `409 identity_conflict`, leaves the sequence unchanged, writes an audit record, and exits 1. The amended corpus cases pass: genuine-content `409`, yanked-record `400`, and timestamp-only `204`. |
| Dependency-bearing archives refused (decision 4) | A tar.gz and a zip whose `lwpt.toml` declares `[dependencies]` each fail locally with `unsupported_dependencies`. A mock origin records no connection, and the token variable is never read. |
| Yank and restore endpoints | A token without the `yank` action, or without a matching pattern, returns 403. Yanking an active version returns `201` with the new record body and `Location`. Repeating it returns `204`. Restoring returns `201`, and repeating that returns `204`. An absent version returns 404. Every replacement record keeps the archive, size, and dependencies. Only `yanked` and `published_at` change, and the old record stays retrievable by hash. |
| Credentials scoped, never printed or persisted | Out-of-scope package returns 403. Revoked and expired tokens return 401. The secret is searched for in every command's stdout and stderr, the audit files, the data directory (hash only), and the project tree. The one exemption is `issue-token`'s single intended stdout line. `lwpt.lock` and `.lwpt/` stay unchanged. |
| Responses echoing the credential | A mock origin reflects the `Authorization` value in its error `message`, `code`, `request_id`, status text, `Location`, `ETag`, `Retry-After`, discovery `origin`, and the text of a transport error. `publish` output never contains the token or its secret; an invalid `code` prints as `unrecognized_error`. A token sent in a request path or query on the server leaves `route = "invalid"` in the audit record and appears in no stderr line. |
| Token expiry bounds | `issue-token` without `--expires-days` sets 90 days. 1 and 365 are accepted. 0, 366, and non-decimal values fail with `invalid_configuration`. A token presented after `expires_at` returns 401. |
| Deterministic limits and authentication | A missing `--key-id` or `--public-key` fails with `invalid_configuration` before any connection. A missing or malformed token returns 401 with the challenge. 413 comes before the body is read. A missing length returns 400. The rate bounds, through `REGISTRY_TESTING` seams (ADR-0044), return 429 with `Retry-After`. The 507 budget and a lease busy past its wait each return their code. |
| Localhost HTTP and remote HTTPS | The E2E matrix runs on every release platform, including both macOS transports. HTTPS uses `localhost-native-identity.p12`, and the client trusts the committed test root through #302 in the `lwpt-testing` build only. Plain HTTP to a non-localhost host fails before connecting. |
| Zip normalization is deterministic | Golden fixtures produce the pinned tar.gz hash on every release platform. The same zip converted twice gives identical bytes. Zips that differ only in entry order, timestamps, stored versus deflate, data descriptors, or comments give the same bytes as each other. |
| Zip features are rejected | Each fails locally with its stable code and no connection: encryption (bits 0 and 6, AES), ZIP64 in each form, multi-disk, unsupported methods and flags, prepended or trailing data, gaps, overlapping entries, local and central mismatch, a descriptor mismatch, and a bad CRC. Negative decoding fixtures: a truncated deflate stream, a stream ending before its slice is consumed, compressed bytes left after `Z_STREAM_END`, output short of or past the declared size, a stored entry whose sizes differ, and a stored entry with a bad CRC. |
| Zip entries are rejected | Each fails locally: symlink, device, FIFO, socket, volume label, absolute and drive paths, `..`, `.`, empty components, `a//`, a lone `/`, a duplicate name, a component over 255 bytes, a path not fitting ustar, invalid UTF-8, and a missing or ambiguous `lwpt.toml` root. Namespace conflicts: file `a` with `a/b`, file `a` with entry `a/`, a case collision between explicit names, and one between implied directories (`A/x` with `a/y`). An explicit `a/` beside `a/b` is accepted. |
| Zip limits are enforced | Inputs just over 256 MiB, 10,001 entries, and 1 GiB declared fail before inflation. An entry that inflates past its declared size fails at that byte. Output over 256 MiB fails. All fail with `archive_limit_exceeded`. |
| A zip retry is idempotent | E2E: publishing a zip gives `201`. Publishing the same zip again gives `204` with the same archive hash. Uploading the tar.gz normalized from it also gives `204`. The project tree is unchanged, and a conversion failure against an unreachable origin makes no connection. |
| Transparency (maintainer amendment) | Inclusion and consistency after `201`/`204`. A stale or downgraded checkpoint after commit fails. A tampered signature or snapshot fails even though the server returned `201`. Offline and frozen: `publish` has no offline mode, and `install --frozen`/`--offline` never contact the publication API. Consumer-side offline proofs stay with #62. |

Unit tests cover token grammar, pattern matching, the content-identity
comparator, record validation, and page cursors. HTTPClient PUT and DELETE get
package-owned tests.

## Considered options

- **Signed requests now.** Rejected for #54. The protocol and corpus pin
  Bearer. Replaying a captured publication is harmless because the operations
  are idempotent and content-addressed, and verified TLS prevents capture.
  Signatures would add nonce storage and a clock policy. They can be added
  later as another `auth_schemes` entry.
- **Accept the whole publication in one request.** Rejected. The corpus pins
  two requests. Separating them also keeps large bodies out of the lease and
  makes a retry resend only what failed.
- **Compare exact record bytes for idempotency.** Rejected because a retried
  CI job, which builds a new record, would conflict with its own earlier run.
- **Stage uploads in `tmp/`.** Rejected because publication and recovery wipe
  it under the lease.
- **Advertise publication from a new config field.** Rejected because it would
  change the origin configuration schema. Active tokens already express
  operator intent.
- **Store and serve zips as a second archive format.** Rejected. Mirrors, the
  protocol media type, the installer, and the content-addressed caches would
  all need a second format. The same package could also get two identities.
- **Gzip with stored deflate blocks only.** Rejected. This would make
  determinism trivial without depending on paszlib's deflate output, but an
  uncompressed tar reaches the 256 MiB object limit far sooner. Golden
  fixtures pin the compressed output instead.
- **Accept ZIP64 or reject data descriptors.** Rejected. Every bound fits the
  classic fields, so ZIP64 would only add a second size field that could
  disagree. Data descriptors are common and are safe once the central
  directory is authoritative and the records must fill the archive without
  gaps.
- **Server-side archive inspection.** Rejected. It adds a decompression-bomb
  surface to a long-running process. The client validates the archive, and
  consumers extract under the installer's protections.

## Consequences

- An origin becomes writable only after its operator issues a token. Existing
  origins, mirrors, and their configuration bytes stay unchanged.
- Package names in `lwpt.toml` must already satisfy the protocol grammar
  (lowercase).
- Unreferenced uploads cost at most 1 GiB. Committed objects and audit records
  grow until a retention design exists.
- Behind a reverse proxy, per-peer rate bounds apply to the proxy address.
  Operators should rely on per-token bounds and their proxy's limits.
- Implementation spans the store, three server transports, HTTPClient, the
  CLI, an in-tree zip reader, and a deterministic tar.gz writer. #302 is a
  delivery dependency for the HTTPS acceptance test.
- Zip input loses symlinks, timestamps, and all permission detail except the
  execute bit. Packages that need more must publish a tar.gz.
- The normalizer's output bytes are a compatibility contract. Upgrading FPC
  or paszlib must keep the golden fixtures passing, or introduce a documented
  normalizer version.

## Decisions

The maintainer settled these on 2026-09-29. All follow the recommendation
except the third, which the maintainer widened to add zip input.

1. **Authentication: Bearer tokens over verified TLS**, as the protocol
   specifies. Replaying a captured idempotent PUT is harmless, and TLS
   prevents capture. Ed25519-signed requests, which #29's summary mentions,
   may be added later as a second `auth_schemes` entry.
2. **Tokens always expire**: 90 days by default, at most 365. Mandatory
   expiry limits how long a leaked CI secret is useful, and overlapping
   validity keeps rotation disruption-free.
3. **Publish input: a prebuilt `.tar.gz` or a `.zip`.** A zip is normalized
   on the client into the one canonical, deterministic tar.gz. Registry,
   mirror, protocol, and installer formats stay single, and retries stay
   idempotent. Directory packing is a follow-up issue that reuses the tar
   writer.
4. **Archives whose `lwpt.toml` declares `[dependencies]` are refused** until
   #62 defines registry dependency sources. Silently dropping dependencies
   would publish packages that install incompletely.
5. **Credentials come from an environment variable only** (`--token-env`,
   default `LWPT_REGISTRY_TOKEN`). Tokens keyed by origin identity in #313's
   user-level config, with owner-only permissions checked, may follow once
   that file exists. Project files never hold credentials.
6. **Private-network origins are allowed.** The destination comes only from
   the invoking user's command line. Run tasks can already execute arbitrary
   commands, so a project gains nothing from naming an origin.
7. **#302 is a delivery dependency, and `publish` has no CLI trust option.**
   The system trust store serves production. A test-only seam in the
   `lwpt-testing` build injects the committed test root.
8. **`publish` requires a trust pin.** It exits 0 only after inclusion and
   consistency are verified, which applies the transparency amendment.
9. **Yank and restore ship as server endpoints and the `yank` action in #54.**
   Their CLI is a follow-up issue. `publication-v1` therefore conforms to the
   corpus.
