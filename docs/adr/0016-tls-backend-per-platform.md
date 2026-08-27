# TLS backends follow each platform's native client stack

> **Amended by [ADR-0024](./0024-openssl-server-tls-accept.md),
> [ADR-0033](./0033-schannel-server-tls-accept-on-windows.md), and
> [ADR-0043](./0043-self-hosted-registry-origin.md).** This ADR governs
> outbound clients. Server accept uses native SChannel on Windows,
> socket-independent memory-BIO OpenSSL on Unix-not-Darwin, and public Secure
> Transport at the HTTPClient seam on macOS. The registry prefers
> Network.framework on macOS 26 and newer and uses Secure Transport on macOS
> 15 and older.

## Executive Summary

- **Outbound TLS is platform-native.** Windows uses SChannel, macOS uses
  SecureTransport, and Unix-not-Darwin runtime-loads the system OpenSSL.
- **LWPT ships no OpenSSL runtime.** Windows and macOS clients need only their
  operating-system TLS stack; Linux users install their distribution's libssl
  package.
- **HTTPClient owns this implementation.** Per
  [ADR-0017](./0017-packages-lwpt-canonical.md), LWPT is the canonical source
  for the package; GocciaScript is a consumer, not an upstream to mirror.
- **Server accept is a separate transport seam.** Its platform-native and
  runtime-loaded implementations do not change the client path.

The `TransportSecurity` unit in
[`packages/httpclient/source/`](../../packages/httpclient/source/) presents one
blocking client API over three platform backends. `HTTPClient` consumes that
API and does not branch by platform:

| Platform | Outbound client backend | Runtime source |
| --- | --- | --- |
| Windows | SChannel | `sspi.dll` / `secur32.dll`, supplied by Windows |
| macOS / Darwin | SecureTransport | Apple framework supplied by macOS |
| Other Unix | OpenSSL | System shared library, loaded at runtime |

## Decision

Outbound clients use the TLS implementation integrated with their platform.
Windows and macOS therefore inherit the operating system's certificate store,
policy, and updates. Unix-not-Darwin uses the system OpenSSL and its default
certificate paths. All three enforce TLS 1.2 or later and verify the peer name
and certificate chain.

LWPT does not bundle, import-link, or otherwise ship OpenSSL. Windows client
releases have no OpenSSL prerequisite; macOS releases do not depend on
Homebrew. Linux and other Unix-not-Darwin installations require the platform's
libssl package.

The package is LWPT-canonical. Changes land in
`packages/httpclient/` under that package's tests and review contract, then
flow to consumers through `lwpt install`. There is no byte-identity promise
against GocciaScript and no patch-marker or upstream-resync policy.

## Historical context

Before ADR-0017 established the current ownership model, this decision was
written while `TransportSecurity` was described as a vendored, byte-identical
copy of GocciaScript source. That description explained the unit's origin at
the time, but it no longer defines ownership or maintenance. The durable part
of this ADR is the per-platform outbound-client decision above.

An earlier documentation spike also described OpenSSL as a Windows and macOS
release prerequisite. The implementation did not match that text: its FPC
conditionals already selected SChannel and SecureTransport, and release
archives did not contain OpenSSL. Correcting those instructions did not change
the outbound implementation or release contents.

ADR-0024 later introduced a separate memory-BIO server seam. ADR-0033 replaced
its Windows implementation with native SChannel. ADR-0043 records the two
native Darwin registry transports: Network.framework on macOS 26 and newer,
and the portable listener using HTTPClient Secure Transport on macOS 15 and
older. Runtime product version, never CPU architecture, selects between them.
The runtime query uses the structured public
`NSProcessInfo.operatingSystemVersion` value; localized display strings are
not parsed.

## Considered options

- **Use OpenSSL for every client platform.** Rejected. It would bypass native
  trust-store integration on Windows and macOS and add a runtime distribution
  obligation with no client benefit.
- **Make the client backend selectable at build time.** Rejected. Per-build
  backend divergence would make release and local behavior differ. The
  platform conditional remains the single client selection rule.
- **Use the native client stack on each platform.** Chosen. It gives Windows
  and macOS zero-install TLS and leaves Unix on its conventional system
  OpenSSL deployment model.
- **Permit server OpenSSL to weaken the Windows import guard.** Rejected.
  Runtime loading and import linking are distinct. The server needs the former;
  release binaries still forbid the latter.

## Consequences

- Windows outbound HTTPS uses SChannel and requires no third-party TLS DLL.
- macOS outbound HTTPS uses SecureTransport and requires no Homebrew OpenSSL.
- Unix-not-Darwin outbound HTTPS requires a discoverable system libssl.
- `HTTPClient` keeps one client-facing API across all three implementations.
- Server consumers follow ADR-0024's separate feed/drain contract and state
  machine; only Unix-not-Darwin has the OpenSSL 3 runtime requirement.
- CI inspects Windows PE imports, imported symbol families, and link inputs so
  runtime loader strings remain permitted while renamed, legacy, delay-loaded,
  or static OpenSSL linkage fails closed.
