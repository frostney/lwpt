# Memory-BIO OpenSSL terminates server TLS on Windows and Unix-not-Darwin

[ADR-0016](./0016-tls-backend-per-platform.md) governs outbound clients:
SChannel on Windows, SecureTransport on macOS, and runtime-loaded OpenSSL on
other Unix systems. Server transports have a different seam. Duetto's Linux
epoll backend owns a nonblocking file descriptor, its Windows IOCP backend
owns an overlapped socket that cannot be handed to OpenSSL, and its macOS
backend already terminates TLS with Network.framework. All three receive one
identity shape: a PKCS#12 file plus passphrase.

`TransportSecurity` therefore provides one socket-independent, memory-BIO
OpenSSL accept implementation on Windows and Unix-not-Darwin. This ADR amends
ADR-0016 only for server accept. The blocking client API and its per-platform
backend choices are unchanged. OpenSSL remains runtime-loaded and is neither
import-linked nor included in LWPT release archives.

## Decision

One `TTransportSecurityServerContext` loads a PKCS#12 identity into an
`SSL_CTX` created with `TLS_server_method`. The bundle is parsed into its leaf
certificate, optional certificate chain, and private key. OpenSSL verifies
that the configured certificate and key match. Context creation errors identify
the failed operation without including the identity path or passphrase.

The context sets TLS 1.2 as its minimum protocol version and applies
`SSL_OP_NO_RENEGOTIATION`. TLS 1.3 remains available when the runtime supports
it. The listener owns the context, reuses it across connections, and must keep
it alive until every connection created from it has been torn down.

`BeginTransportSecurityServer` creates one `SSL`, one read memory BIO, and one
write memory BIO per connection. `SSL_set_bio` transfers both BIOs to that
`SSL`; no server path calls `SSL_set_fd`, reads a socket, writes a socket, or
blocks. OpenSSL supports concurrent connections through the shared immutable
`SSL_CTX`, while the consumer serializes access to each individual `SSL`.

## Completion-shaped state machine

Handshake, plaintext read, plaintext write, and graceful close expose
`tssDone`, `tssWantRead`, `tssWantWrite`, or `tssError`. Each call performs at
most one OpenSSL protocol operation. There is no retry loop: the transport
feeds received ciphertext, calls one step, and resumes after its next readiness
or completion event.

The ciphertext surface is deliberately peek/consume shaped:

1. `TransportSecurityFeedCiphertext` writes received bytes to the read BIO.
2. An operation runs once and moves all write-BIO output into the connection's
   retained ciphertext queue.
3. `TransportSecurityGetCiphertext` returns the current queue head and length.
4. The transport offers that span to `SubmitSend`, then calls
   `TransportSecurityConsumeCiphertext` only for the accepted prefix.
5. A short send leaves the exact remainder queued for `OnSendReady` to offer
   again. TLS record bytes are never discarded or regenerated around transport
   backpressure.

Pending ciphertext takes precedence over `SSL_ERROR_WANT_READ`: the operation
returns `tssWantWrite` until the caller flushes it, then a later step reports
`tssWantRead` or `tssDone`. Plaintext writes report both bytes accepted and the
next state. Plaintext reads clamp the requested length to the supplied open
array before calling OpenSSL.

Immediately before every `SSL_accept`, `SSL_read`, and `SSL_write`, the code
clears OpenSSL's thread-local error queue. `SSL_get_error` is called before any
other OpenSSL operation can disturb classification. `SSL_ERROR_SSL`,
`SSL_ERROR_SYSCALL`, and every other non-retry fatal result poison the
connection: TLS state is freed without `SSL_shutdown`, `Active` becomes false,
and later calls report an error.

## Close semantics

`CloseTransportSecurityServerGracefully` calls `SSL_shutdown` once and queues
the resulting `close_notify` ciphertext. The transport flushes that retained
output before closing its socket, then calls `AbortTransportSecurityServer` to
release the connection state. Hard close, peer failure, listener shutdown, and
fatal TLS errors use the abortive path directly; it never calls
`SSL_shutdown`. Neither path owns or closes the transport's socket.

## Platform and runtime consequences

- **Linux and other Unix-not-Darwin:** client and server paths share the
  runtime-loaded system OpenSSL libraries. Epoll feeds bytes from `fpRecv` and
  offers queued ciphertext to `fpSend`.
- **Windows:** outbound clients remain on SChannel. Server consumers provide a
  compatible OpenSSL runtime; IOCP feeds `WSARecv` completions and offers
  queued ciphertext through `WSASend`.
- **Darwin:** the server types and functions remain compile-present, but the
  context constructor raises an actionable error directing the caller to
  Network.framework. There is no OpenSSL server backdoor on macOS.

FreePascal 3.2.2's compiled `openssl` unit exposes PKCS#12 parsing,
`BIO_ctrl`, certificate/private-key installation, and the core SSL calls, but
does not expose the complete memory-BIO and SSL BIO-wiring surface. The unit
therefore resolves the missing C exports through `SSLLibHandle` and
`SSLUtilHandle`, matching the existing `TLS_server_method` resolution pattern.

On Windows, FreePascal's loader still accepts bare OpenSSL DLL names. Server
operators must install those DLLs in an administrator-controlled trusted DLL
search directory, never a user-writable working directory. Changing the shared
loader to accept absolute configured paths is separate work because it also
affects the existing Unix client path.

The Windows CI guards parse both the normal PE import directory and the delay
import directory. Import-linked or delay-imported `libssl` / `libcrypto` fails
closed; runtime-loader strings remain expected.

## Considered options

- **Socket BIO plus blocking `SSL_accept`.** Rejected. It cannot serve IOCP,
  blocks the epoll reactor, and does not fit duetto's completion contract.
- **Separate SChannel and OpenSSL server implementations.** Rejected. Server
  identity presentation does not benefit from client trust-store integration,
  and two state machines would create needless platform divergence.
- **One memory-BIO OpenSSL implementation for epoll and IOCP.** Chosen. It
  separates protocol state from socket ownership and makes the entire protocol
  path deterministically testable without a network socket.
- **OpenSSL server support on Darwin.** Rejected. Duetto's macOS transport
  already owns native TLS through Network.framework.

## Deferred hardening

The following remain explicit consumer or follow-up responsibilities:

- handshake deadlines and timeout enforcement in the transport;
- context refcounting for reload-during-accept races (the listener currently
  keeps the context alive until its connections are gone);
- strict certificate-chain and expiry validation of the configured server
  identity;
- callback-driven password policy for encrypted key sources other than the
  explicit PKCS#12 passphrase;
- removal of the file-load TOCTOU window through a caller-supplied byte or
  handle API; and
- an absolute-path Windows OpenSSL loader configuration.

The implementation does include path/passphrase-safe errors, a short-lived
`CA:FALSE`/`serverAuth` test leaf, the read bounds clamp, error-queue clearing,
fatal-state poisoning, renegotiation disablement, trusted-directory deployment
guidance, and normal-plus-delay PE import inspection.
