# Self-hosted registry origin lifecycle

Issue [#53](https://github.com/frostney/lwpt/issues/53) turns the registry
protocol from [a wire contract](../registry-spec.md) into an origin that the
LWPT executable can initialize and run. The command surface is
`lwpt registry init|serve`: one ADR-backed command family with lifecycle
operations below it, rather than two unrelated top-level subcommands. This is
the interface approved by the registry parent issue and preserves the frozen
top-level vocabulary as one cohesive capability.

`registry init` accepts `--data-dir`, `--identity`, `--base-url`, `--listen`,
`--port`, `--tls-pkcs12`, and `--tls-password-env`. Its deterministic defaults
are `.lwpt/registry`, `http://localhost:8080`, `localhost`, and port `8080`.
On first initialization the canonical base URL becomes the identity unless an
explicit canonical HTTPS identity is supplied. Later initialization may move
the base URL or listener and atomically updates operational configuration, but
an existing identity cannot change. `registry serve` opens that data directory
and remains in the foreground; process supervisors own daemonization and
restart policy.

## Storage and activation

The data directory is an origin, not an install cache:

```text
registry.toml
keys/root.seed
keys/ed25519-<public-key-hash>.toml
objects/sha256/<hash>
records/sha256/<hash>.toml
snapshots/sha256/<hash>.toml
checkpoints/<sequence>.toml
checkpoints/<sequence>.sig.toml
checkpoints/renewals/sha256/<checkpoint-hash>.toml
checkpoints/renewals/sha256/<checkpoint-hash>.sig.toml
indexes/sha256/<package-name-hash>.toml
state/current.toml
locks/
tmp/
```

Archives and protocol metadata are immutable at their content-addressed path.
Writing different bytes to an occupied path is an `immutable_conflict`.
Publishing an existing `(origin, name, version)` with identical bytes is
idempotent; different bytes are an `identity_conflict`. A per-package version
index is replaced atomically and is a derived lookup aid, not a trust root.
Its filename is the SHA-256 of the canonical UTF-8 package name, so every
protocol-valid name has the same safe storage key on Windows, macOS, and Unix.

Publication writes the archive, record, next snapshot, checkpoint, and
detached signature before replacing `state/current.toml`. That one small
atomic pointer is the authority for the complete committed checkpoint,
signature, and snapshot. Derived version indexes are atomically replaced only
after activation and are rebuilt from the active snapshot after a crash. An
index or numeric checkpoint ahead of the pointer is never publication proof
and cannot make a retry idempotent or consume a sequence.

Publication takes an operating-system advisory producer lease. Its persistent
guard and diagnostic files do not establish liveness: the kernel lock is
released when a process exits. Startup reclaims `tmp/` only after acquiring
that lease, then verifies the activated snapshot hash, checkpoint relationship,
key record, signature payload, and Ed25519 signature. If a publisher is live,
startup leaves its staging alone and serves the previous committed pointer.
Initialization and operational reconfiguration use a separate operating-system
lease from marker inspection through commit. Recovery removes only enumerated
origin-owned artifacts carrying a valid initialization marker; it never wipes
the caller's data root. Every registry path rejects symbolic-link and reparse
components before reads, writes, recovery, or serving.

All committed-state writes use atomic replacement. The private seed has a
stricter creation path: staging and destination are private from their first
open, Unix mode `0600` or the Windows owner-and-system ACL is verified before
commit, and initialization fails closed if that cannot be guaranteed. The
password is read from the named environment variable only while constructing
the TLS listener, and its mutable buffer is wiped before the listener run loop
begins; it is never persisted. The PKCS#12 path is persisted as an absolute
path so a supervisor may restart from another working directory. Its components
are opened without following links, and a nonblocking retained handle must name
a regular file before any bytes are imported.

An active checkpoint is renewed when less than 24 hours of its seven-day
validity remains. Renewal keeps the package sequence and snapshot unchanged,
writes a content-addressed checkpoint and signature, then atomically replaces
the same state pointer. Historical sequence checkpoint bytes never change.

## Signing and diagnostics

`LWPT.Registry.Crypto` is the shared signing and verification primitive for
origin, mirror, resolver, and cache consumers. It implements SHA-512 and
RFC 8032 Ed25519 in Pascal, produces the same bytes on every release platform,
uses platform secure randomness only for seed generation, rejects non-canonical
signature scalars, noncanonical field encodings, and small-order public keys
and `R` points. RFC 8032 positive vectors and negative forgery vectors pin the
behavior. It does not select OpenSSL, Security.framework, or CNG signing APIs,
which prevents provider defaults from changing registry identity across
platforms.

Registry failures begin with a stable lowercase reason code followed by a
colon, including `insecure_transport`, `identity_conflict`,
`immutable_conflict`, `publication_locked`, `snapshot_hash_mismatch`,
`signature_payload_mismatch`, and `signature_invalid`. Human detail may grow;
consumers branch only on the code.

## Listener and TLS lifecycle

Plain HTTP is accepted only when the canonical base URL host is the exact name
`localhost` and the listener is `localhost` or `127.0.0.1`. A wildcard,
private address, or other host produces `insecure_transport` before serving.

HTTPS uses the repository's native server policy:

- Windows uses the HTTPClient package's native SChannel server context.
- Unix other than Darwin uses its runtime-loaded OpenSSL 3 memory-BIO server
  context.
- macOS imports the configured PKCS#12 identity into a process-private
  temporary keychain, validates its bundled chain with a private anchor and
  Apple's server policy, and serves with Network.framework. FPC 3.2.2 reaches
  the Network C API through the stable blocks ABI, with one serial queue per
  connection.

The portable socket listeners on Windows and Unix other than Darwin accept
`localhost` or an IPv4 address. Initialization rejects other listener families
there rather than persisting a configuration that can fail only at `serve`.
The macOS Network.framework listener also accepts IPv6 addresses.

The listener admits at most 32 owned connections, handles each independently,
and closes it after one bounded HTTP/1.1 GET or HEAD request. One ten-second
monotonic deadline covers handshake, request, and response; request headers are
capped at 32 KiB. Committed-state reads and hashes report progress in 64 KiB
steps to the same deadline before routing may select a resource. A response
resource is capped at 2,147,483,647 bytes, matching the platform-safe maximum
accepted by the current publication and state-loading surface. The listener
opens every path component without following links,
retains verified parent handles through a nonblocking regular-file open, checks
the resource length and digest in cancellable 64 KiB steps, rewinds that retained
handle, and sends from the same handle through one connection-owned buffer. The
route descriptor carries the authoritative digest for content-addressed files;
other routed files are hashed under the same deadline, so the later retained
delivery handle must prove the exact bytes that routing accepted. The
same retained component-safe boundary protects committed configuration, state,
checkpoint, signature, index, and signing-seed reads during startup, recovery,
and publication. The listener never builds a second body-sized wire response in
memory. Shutdown
interrupts acceptance, cancels every client, drains
its workers or Network.framework callbacks, and only then releases the store
and TLS context. Hashed objects, records, and snapshots are SHA-256 checked
again before every response and receive immutable cache headers. Checkpoint
aliases and historical checkpoint paths require cache revalidation.

Discovery and capabilities advertise only the implemented read surface:
checkpoint, key, package-record, snapshot, and object schemas with
`snapshot-sync-v1`. Package lists and publication remain issue #54; rotation
chains remain issue #55. Neither future feature is advertised by this origin.

## Rejected alternatives

- **Run tasks as the server interface.** Run tasks launch user commands and
  cannot own persisted identity, generated trust roots, recovery, or a stable
  cross-project contract.
- **Extend project `init`.** Project scaffolding and registry-origin creation
  have unrelated state, secrets, and lifecycle rules.
- **Rewrite `latest.toml` and `latest.sig.toml` independently.** Two renames
  permit a reader to observe a checkpoint and signature from different
  publications. The activation pointer makes their relationship atomic.
- **Use cache eviction or mutable object paths.** An origin is authoritative
  durable state. Cache policy must never remove a snapshot ancestor or replace
  published bytes.
- **Select a platform Ed25519 provider.** Provider-specific parsing and
  canonicality behavior would make signatures and diagnostics drift between
  release targets.

## Consequences

The origin can be hosted directly by LWPT and supervised by any ordinary
process manager. Old snapshots and objects accumulate until an explicit,
protocol-aware retention design is approved; general cache repair and eviction
must not touch them. Remote publication, mirror synchronization, and registry
dependency resolution build on this store and shared crypto unit in issues #54
and #55.
