# Memory-BIO OpenSSL terminates server TLS on Windows and Unix-not-Darwin

## Executive Summary

- **Server TLS is socket-independent.** One nonblocking memory-BIO OpenSSL
  state machine serves Windows IOCP and Unix reactors; Darwin continues to use
  Network.framework.
- **OpenSSL 3 or newer is mandatory for servers.** It is runtime-loaded, never
  import-linked or shipped by LWPT, and Windows loading excludes the current
  directory and ordinary `PATH` search.
- **A connection is active only after authentication.** `Active` remains false
  until `SSL_accept` succeeds; `tssPeerClosed` explicitly reports a peer
  `close_notify` from the read path.
- **Backpressure is lossless at the TLS seam.** Retained ciphertext always
  drains before another protocol operation, and plaintext for a WANT-write
  retry is retained internally.
- **Socket policy remains with the consumer.** The reactor must enforce a
  handshake deadline and byte budget; broader flow control and reload safety
  remain deferred below.

[ADR-0016](./0016-tls-backend-per-platform.md) governs outbound clients:
SChannel on Windows, SecureTransport on macOS, and runtime-loaded OpenSSL on
other Unix systems. Server transports have a different seam. Duetto's Linux
epoll backend owns a nonblocking file descriptor, its Windows IOCP backend owns
an overlapped socket that cannot be handed to OpenSSL, and its macOS backend
already terminates TLS with Network.framework. All three receive the same
identity shape: a PKCS#12 file plus passphrase.

`TransportSecurity` therefore provides a socket-independent memory-BIO OpenSSL
server implementation on Windows and Unix-not-Darwin. This ADR amends ADR-0016
only for server accept. The blocking client API and its per-platform backend
choices are unchanged. OpenSSL remains runtime-loaded and is neither
import-linked nor included in LWPT release archives.

## Decision

One `TTransportSecurityServerContext` loads a PKCS#12 identity into an
`SSL_CTX` created with `TLS_server_method`. The bundle supplies a leaf
certificate, private key, and optional intermediate chain. The complete chain
is installed and OpenSSL verifies that the leaf and private key match.

Context construction enforces a named 16 MiB PKCS#12 size cap before allocating
or parsing the file. Passphrases are converted deliberately to UTF-8, embedded
NUL bytes are rejected, and empty and non-ASCII passphrases are supported. The
temporary passphrase buffer and in-memory bundle bytes are zeroed in a
`finally` path after parsing. Errors identify the failed operation without
including the identity path or passphrase.

The context sets TLS 1.2 as its minimum protocol version and applies
`SSL_OP_NO_RENEGOTIATION`; failure to establish either policy aborts context
construction. TLS 1.3 remains available. The listener owns the context, reuses
it across connections, and must keep it alive until every connection created
from it has been torn down.

`BeginTransportSecurityServer` creates one `SSL`, one read memory BIO, and a
bounded write-side memory BIO pair per connection. `SSL_set_bio` transfers the
read BIO and the protocol side of the pair to that `SSL`; no server path calls
`SSL_set_fd`, reads a socket, writes a socket, or blocks. OpenSSL supports
concurrent connections through the shared immutable `SSL_CTX`, while the
consumer serializes access to each individual `SSL`.

## Runtime loading

Server context construction requires OpenSSL 3 or newer. The loader resolves
the runtime version and rejects a major version below 3 with an actionable
error before it creates an `SSL_CTX`. Server loading does not fall back to
OpenSSL 1.1 names. This server check does not change the already-established
outbound-client path.

On Windows, OpenSSL DLLs are opened with `LoadLibraryEx` and restricted
system/default-directory search flags. The loader does not search the current
working directory or ordinary `PATH`; the default-directory set includes the
application directory, so the executable's installation directory must also
be administrator-controlled. The consumer supplies an OpenSSL 3 runtime in a
directory covered by that restricted policy. LWPT does not ship it.

FreePascal 3.2.2's compiled `openssl` unit does not expose the complete
memory-BIO, BIO-wiring, stack, and runtime-version surface. The implementation
resolves the missing C exports dynamically. It resolves into local procedure
variables and publishes the procedure table only after every required server
symbol has been validated, so a partial failure cannot masquerade as a
completed initialization on retry.

## Completion-shaped state machine

Handshake, plaintext read, plaintext write, and graceful close expose
`tssDone`, `tssWantRead`, `tssWantWrite`, `tssPeerClosed`, or `tssError` as
applicable. Each call performs at most one OpenSSL protocol operation. There is
no readiness loop inside the package: the transport feeds received ciphertext,
calls one step, and resumes after its next readiness or completion event.

`Active` means the peer is authenticated and the handshake is established. It
is false after `BeginTransportSecurityServer` allocates the private backend
state and becomes true only when `SSL_accept` returns success. The consumer
starts its handshake deadline when Begin returns and can observe progress from
the WANT results; it must not infer authentication from allocation alone.

The ciphertext surface is deliberately peek/consume shaped:

1. `TransportSecurityFeedCiphertext` writes received bytes to the read BIO.
2. An operation runs once and moves write-BIO output into the connection's
   retained ciphertext queue.
3. `TransportSecurityGetCiphertext` returns the current queue head and length.
4. The transport offers that span to its asynchronous send API, then calls
   `TransportSecurityConsumeCiphertext` only for the accepted prefix.
5. A short send leaves the exact remainder queued for the next send-ready
   event.

Retained ciphertext takes precedence before every handshake, read, write, or
close protocol operation. While any bytes remain, the operation immediately
returns `tssWantWrite` without calling OpenSSL or modifying/reallocating the
queue. A span returned by `TransportSecurityGetCiphertext` is therefore stable
until its accepted prefix is consumed. TLS record bytes are never discarded or
regenerated around transport backpressure.

When `SSL_write` returns WANT, the connection retains the unaccepted plaintext
internally. After ciphertext drains, a later write step resumes that exact
buffer with a nil, zero-length input; the caller does not need to keep or replay
the original pointer. The bounded BIO pair makes this retry path deterministic
without turning the package into the owner of transport flow control. A
successful positive-length write can report `tssDone` only after OpenSSL
accepts a positive number of bytes.

Plaintext reads clamp the requested length to the supplied open array before
calling OpenSSL. `SSL_ERROR_ZERO_RETURN` means the peer sent `close_notify`,
not successful zero-byte I/O. During a read it returns `tssPeerClosed` and
releases the TLS connection; during handshake it is fatal. It never turns a
positive-length write into zero-byte `tssDone`.

Immediately before each OpenSSL protocol operation, the implementation clears
the thread-local error queue. `SSL_get_error` is called before another OpenSSL
operation can disturb classification. `SSL_ERROR_SSL`, `SSL_ERROR_SYSCALL`,
and every other non-retry fatal result poison the connection: TLS state is
freed without another `SSL_shutdown`, retained output and pending plaintext are
discarded, `Active` is false, and later calls report an error. The blocking
OpenSSL client path follows the same error-queue discipline.

## Close semantics

`CloseTransportSecurityServerGracefully` first honors retained-ciphertext
precedence, then calls `SSL_shutdown` once. On a successful or retryable result,
it queues the resulting `close_notify` ciphertext for the transport to flush.
If shutdown fails, it classifies the error before collecting write-BIO output;
a fatal `SSL_ERROR_SSL` or `SSL_ERROR_SYSCALL` therefore poisons the connection
and discards output instead of leaving an apparently active WANT-write state.

After a graceful close has drained, the consumer calls
`AbortTransportSecurityServer` to release remaining connection state. Hard
close, peer failure, listener shutdown, and fatal TLS errors use the abortive
path directly. Neither path owns or closes the transport socket.

## Platform and CI consequences

- **Linux and other Unix-not-Darwin:** client and server paths share the
  runtime-loaded system libraries; server context construction additionally
  enforces OpenSSL 3 or newer. The caller-owned reactor feeds and drains bytes.
- **Windows:** outbound clients remain on SChannel. Server consumers supply an
  OpenSSL 3 runtime discoverable through the restricted DLL search. IOCP feeds
  receive completions and submits retained ciphertext through asynchronous
  sends.
- **Darwin:** the server types and functions remain compile-present, but the
  context constructor raises an actionable error directing the caller to
  Network.framework. There is no OpenSSL server backdoor on macOS.

The guards in `pr.yml`, `ci.yml`, and `release.yml` inspect normal and delay PE
imports, imported OpenSSL symbol families regardless of DLL filename, and
linker-map/archive evidence for static OpenSSL. Matching happens inside the
checker so an absent or failing text-search command cannot become a clean
result. A small prohibited-import PE fixture is a positive canary for the
checker; the real binary must also expose at least one known system import so a
parser regression that returns an empty set fails closed. Runtime-loader names
remain permitted because they are not imports.

## Considered options

- **Socket BIO plus blocking `SSL_accept`.** Rejected. It cannot serve IOCP,
  blocks the epoll reactor, and does not fit the completion contract.
- **Separate SChannel and OpenSSL server implementations.** Rejected. Server
  identity presentation does not benefit from client trust-store integration,
  and two state machines would create needless platform divergence.
- **One memory-BIO OpenSSL implementation for epoll and IOCP.** Chosen. It
  separates protocol state from socket ownership and makes the protocol core
  deterministic in tests.
- **OpenSSL server support on Darwin.** Rejected. Duetto's macOS transport owns
  native TLS through Network.framework.
- **Require callers to replay the same write buffer after WANT.** Rejected.
  Retaining the plaintext inside the connection is safer for asynchronous
  callers and makes buffer lifetime unambiguous.

## Deferred hardening

The following are deliberately outside this package's present contract:

- **Handshake deadline and byte-budget enforcement.** The package does not own
  the socket, clock, or reactor. Every consumer **MUST** start and enforce a
  handshake deadline and inbound byte budget from
  `BeginTransportSecurityServer`; the WANT states and `Active` established flag
  expose enough state to do so.
- **Full inbound and outbound flow control.** The PKCS#12 size cap and stable
  retained-ciphertext queue are implemented, but broader per-connection
  backpressure, watermarks, and admission policy belong to a future transport
  flow-control API.
- **Server-context refcounting for concurrent reload.** A listener must keep
  its context alive until all accepted connections are destroyed. Atomic
  identity reload while accepts race requires reference-counted context
  ownership in a later change.
- **Certificate policy validation at context creation.** Private-key matching
  and chain loading are implemented. Expiry, server-purpose, and full
  chain-sanity policy checks remain deferred.
- **PKCS#12 file TOCTOU hardening.** The current path-based load has a metadata
  check/read window. An open-once, no-follow, caller-supplied byte/handle API is
  deferred.
