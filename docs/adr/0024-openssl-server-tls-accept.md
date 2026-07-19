# OpenSSL terminates server-side TLS on Windows and Unix-not-Darwin

[ADR-0016](./0016-tls-backend-per-platform.md) selected platform-native TLS
for outbound clients: SChannel on Windows, SecureTransport on macOS, and
runtime-loaded OpenSSL on other Unix systems. Server-side TLS has a different
constraint. An fd-owning server presents caller-supplied credentials rather
than verifying a peer against the OS trust store, and it needs one reusable
certificate context to accept many caller-owned sockets. The
`TransportSecurity` accept path therefore uses OpenSSL, loaded dynamically
through FreePascal's existing `OpenSSL` unit, on Windows and Unix-not-Darwin.
Accepted sessions join the existing `TTransportSecurityConnection` read,
write, and close interface. This amends ADR-0016 only for server accept;
outbound client selection and verification are unchanged. OpenSSL remains a
runtime prerequisite for the server consumer, never an import-linked or
shipped LWPT dependency.

## Considered Options

- **Runtime-loaded OpenSSL for server accept on Windows and
  Unix-not-Darwin.** *Chosen.* One mature fd-oriented implementation covers
  the first consumer's Linux epoll server and Windows without coupling server
  certificate presentation to client trust-store integration. This follows
  the precedent of Node `ws`, uWebSockets, CPython `websockets`, and SwiftNIO,
  whose fd-owning server stacks use an OpenSSL-family backend.
- **Linux-only OpenSSL accept support.** Rejected because Windows accept
  support is part of the first complete public interface rather than a later
  compatibility fork.
- **SChannel and SecureTransport server modes.** Rejected because they would
  duplicate the accept implementation per platform without improving server
  trust behavior. SecureTransport server mode is deprecated and capped at
  TLS 1.2, making it a poor new server foundation.

## macOS

The OpenSSL accept path is not compiled on Darwin. Creating a server context
fails at runtime with an actionable error directing callers to
Network.framework, which is duetto's native macOS server backend and owns its
TLS termination. This keeps LWPT documentation about shipped behavior precise
without adding a deprecated SecureTransport server implementation or a new
macOS OpenSSL prerequisite.

## Consequences

- `TTransportSecurityServerContext` loads a PEM certificate chain and private
  key once, validates that they match, and can create many accepted sessions.
- `StartTransportSecurityServer` performs the blocking TLS accept handshake on
  a caller-owned socket. `CloseTransportSecurity` releases TLS state but does
  not close that socket.
- Windows outbound HTTPS still uses SChannel and requires no OpenSSL DLL.
  Windows programs using the accept interface must make a compatible OpenSSL
  runtime available through the normal DLL search path; LWPT does not ship
  those DLLs.
- Windows CI guards inspect the PE import table and reject import-linked
  `libssl` or `libcrypto`. Runtime-loader name strings are expected and no
  longer constitute a failure.
