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
| Readers capture the pointer under the generation lock | `Store.pas:2436-2445`, `2545-2570` |
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
  line. Failures exit 1 with `registry: <code>: <message>` on stderr.
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
pinned by the specification and the corpus. It advertises `package-list-v1`
on origins and mirrors, because pages derive from the captured read view.
Origins additionally advertise `publication-v1` with `auth_schemes =
["bearer"]` while at least one active token exists. Otherwise they stay
read-only, exactly as today.

- **Package reads.** `GET /v1/packages`, `/v1/packages/<name>`, and
  `/v1/packages/<name>/<version>` are computed from the snapshot named by the
  `snapshot` parameter, or from the captured head on a first page. That
  snapshot must be in accepted history. Cursors bind the snapshot. A mismatch
  returns `409 snapshot_conflict`, and `limit` is at most 100. Only these
  routes accept a query, and they decode percent-encoding strictly.
- **Upload.** `PUT /v1/objects/sha256/<hex>` streams to
  `incoming/<random>.part` while hashing, then moves to
  `incoming/sha256/<hex>`. A new object returns `201`. An object already
  incoming or committed returns `204`, and a digest mismatch returns
  `422 object_hash_mismatch`. Nothing under `incoming/` is served, since
  serving is membership-based (ADR-0045). Uploads use `incoming/`, not `tmp/`,
  so a concurrent commit or recovery cannot wipe them.
- **Publish.** `PUT /v1/packages/<name>/<version>` carries a canonical package
  record whose name and version equal the path and whose origin equals the
  configured identity, with `yanked = false`. When a record for that identity
  is already active, the server compares **content identity**: `archive`,
  `archive_size`, and `dependencies`, but not `published_at` or `yanked`.
  Equal content returns `204` with the active record, even if it is yanked.
  Different content returns `409 identity_conflict`. For a new version, the
  server requires `published_at` to be within five minutes of its own clock,
  and the archive object must be incoming or committed with the stated size.
  If it is not, the server returns `424 failed_dependency`.
- **Yank/restore.** `PUT` and `DELETE` on `/v1/packages/<name>/<version>/yank`
  work as specified and use the same commit path.
- **Responses.** `201` and `204` carry
  `Location: <base>/v1/records/sha256/<hex>.toml` for the active record.
  Errors use `lwpt-registry-error-v1` with a per-request `request_id`.

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
- Unreferenced uploads may total at most 1 GiB. The next lease holder deletes
  uploads older than one hour.
- At most two request bodies may be in flight. The body deadline is 30 seconds
  plus one second per MiB declared.
- Each token may make 60 mutating requests per minute. Each peer address may
  make 20 failed authentications per minute.
- A commit waits up to 5 seconds for the lease.

Rate state is in memory and resets on restart. The server applies
authentication, length, and concurrency checks after reading the headers and
before reading the body.

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
commit. Readers capture one pointer under the generation lock, so they see
the old or the new signed head and never a mix. The response is sent only
after the pointer is replaced, which means a lost `201` becomes a `204` on
retry. The recovery rules from ADR-0043 are unchanged. Files ahead of the
pointer are not proof, recovery removes numeric checkpoints ahead of it, and
`.part` uploads left by a killed process are cleaned by the next lease holder.
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
  transport, and wipes its buffer after the last request. A missing or
  malformed token fails locally with `credential_missing` or
  `credential_invalid`, naming the variable but never the value. Tokens are
  never read from or written to `lwpt.toml`, `lwpt.lock`, `.lwpt/`, logs, or
  diagnostics. Server error bodies are printed only as their code and
  `request_id`, plus the message with control characters stripped and capped
  at 512 bytes.

### Audit records

Every mutating request writes one immutable file,
`audit/<yyyy>/<mm>/<dd>/<received-at>-<request-id>.toml`
(`lwpt-registry-audit-v1`), through the atomic helpers. The file records:

- the request ID, receive and completion times, and the socket peer address
  (forwarded headers are not trusted);
- the method and route;
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
- **zip** is normalized on the client into one canonical tar.gz, described
  in the next section. Only that tar.gz is uploaded, stored, hashed, and
  served.

For both formats, the identity checks and decision 4's dependency rule run
on the resulting tree. The server never decompresses archives. It binds only
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
- Each entry is inflated with `zinflate`. It must produce exactly its
  declared size, and inflation stops one byte past that size. The entry's
  CRC-32 must also match.

**Entry rules.** These are the tar preflight's rules applied to each name,
followed by rules that the canonical form needs:

- The name must be strict UTF-8 with no control characters. `\` is read as
  `/`, as the installer does.
- The same rules reject empty, absolute (`/`, `\`, or a drive letter), and
  `..` paths, and any component longer than 255 bytes.
- `.` and empty components are rejected as well.
- Duplicate names are rejected. Names that collide after ASCII case folding
  are also rejected on every platform, so a package extracts the same way on
  case-insensitive Windows and macOS.
- Only regular files and directories are allowed. A directory name ends
  with `/`, has size 0, and has CRC 0.
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
(`zstream.pp:120-122`). `zdeflate` is therefore already built for every
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

### Test plan

| Acceptance criterion | Evidence |
| --- | --- |
| A CI client publishes to a running origin | E2E: `registry init`, then `serve`, then `issue-token`, then `publish` over localhost HTTP. The server PID stays the same and served reads show the new head. |
| Readers see the old or new head | E2E: a reader loop verifies every checkpoint, signature, and snapshot with the shared verifier while `publish` holds the publication barrier. Store test: `checkpoint` and `activation` failure points leave the old head. |
| Crash mid-publish | E2E: kill `serve` at the barrier, restart, get the old head, retry, and get `201` at the same next sequence. Kill during an upload, and the `.part` file is reclaimed. |
| Identical retry succeeds | Same archive, a fresh `published_at`, and a lost-response retry each return `204` with an unchanged sequence and exit 0. |
| Conflicting content rejected | A different archive for an existing version returns `409 identity_conflict`, leaves the sequence unchanged, writes an audit record, and exits 1. |
| Credentials scoped, never printed or persisted | Out-of-scope package returns 403. Revoked and expired tokens return 401. Every command's stdout and stderr, the audit files, the data directory (hash only), and the project tree are searched for the secret. `lwpt.lock` and `.lwpt/` stay unchanged. |
| Deterministic limits and authentication | Missing or malformed token returns 401 with the challenge. 413 comes before the body is read. A missing length returns 400. The rate bounds, through `REGISTRY_TESTING` seams (ADR-0044), return 429 with `Retry-After`. The 507 budget and a lease busy past its wait each return their code. |
| Localhost HTTP and remote HTTPS | The E2E matrix runs on every release platform, including both macOS transports. HTTPS uses `localhost-native-identity.p12`, and the client trusts the committed test root through #302 in the `lwpt-testing` build only. Plain HTTP to a non-localhost host fails before connecting. |
| Zip normalization is deterministic | Golden fixtures produce the pinned tar.gz hash on every release platform. The same zip converted twice gives identical bytes. Zips that differ only in entry order, timestamps, stored versus deflate, data descriptors, or comments give the same bytes as each other. |
| Zip features are rejected | Each fails locally with its stable code and no connection: encryption (bits 0 and 6, AES), ZIP64 in each form, multi-disk, unsupported methods and flags, prepended or trailing data, gaps, overlapping entries, local and central mismatch, a descriptor mismatch, and a bad CRC. |
| Zip entries are rejected | Each fails locally: symlink, device, FIFO, socket, volume label, absolute and drive paths, `..`, `.`, empty components, a duplicate or ASCII case-colliding name, a component over 255 bytes, a path not fitting ustar, invalid UTF-8, and a missing or ambiguous `lwpt.toml` root. |
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
