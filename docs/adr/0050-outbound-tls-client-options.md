# Outbound TLS client options: trust anchors, client identity, insecure mode, and peer identity

> **Amends [ADR-0016](./0016-tls-backend-per-platform.md).** Outbound
> clients still use each platform's native TLS stack and verify the peer by
> default. A caller may now add trust anchors, present a client certificate,
> read the verified peer certificate, or explicitly opt out of verification.

## Executive Summary

- **One options record, zero value unchanged.** `TTransportSecurityClientOptions`
  carries trust anchors, a trust mode, a PKCS#12 client identity, and
  `InsecureSkipVerify`. A zero-valued record takes exactly the code path of
  the option-less `StartTransportSecurity` overloads, so existing callers and
  `HTTPClient` defaults behave byte for byte as before.
- **Trust anchors are native on every backend, but "system plus anchors" is
  not symmetric.** macOS expresses both modes on one `SecTrust`. OpenSSL adds
  the anchors to a store that also holds the default paths. Windows has no
  merged evaluation, so it evaluates against the system engine and then
  against an exclusive-anchor engine, and accepts either.
- **Client identities reuse the server's PKCS#12 importers.** Windows imports
  into a persisted CNG key that the connection deletes when it closes, macOS
  uses the temporary-keychain lifecycle, and OpenSSL parses in memory.
- **Insecure mode is loud, explicit, and exclusive.** It skips chain and
  host-name checks, never applies by default, cannot be combined with
  anchors, and never follows an HTTPClient redirect to another origin.
- **`TransportSecurityPeerCertificate` returns the peer leaf as DER** on
  every client backend, whatever options were used.

Issue [#302](https://github.com/frostney/lwpt/issues/302) asked for the four
things TLS clients routinely need. The first consumer is duetto's WebSocket
client, which could only trust a private CA through `SSL_CERT_FILE` (OpenSSL
only). Registry publication
([#54](https://github.com/frostney/lwpt/issues/54)) also needs HTTPClient to
trust a private CA, including the committed test root in its HTTPS tests.

## Decision

### API

```pascal
TTransportSecurityTrustMode = (tstmSystemAndAnchors, tstmAnchorsOnly);

TTransportSecurityClientOptions = record
  TrustAnchors: TBytes;            { PEM CERTIFICATE blocks or one DER cert }
  TrustMode: TTransportSecurityTrustMode;
  ClientPkcs12: TBytes;
  ClientPkcs12Passphrase: UnicodeString;
  InsecureSkipVerify: Boolean;
end;

procedure StartTransportSecurity(var AConnection; const ASocket; const AHost;
  const AOptions: TTransportSecurityClientOptions[; ADeadline, ATimeout]);
function TransportSecurityPeerCertificate(const AConnection): TBytes;
procedure ValidateTransportSecurityClientOptions(const AOptions);
function DefaultTransportSecurityClientOptions: TTransportSecurityClientOptions;
function TransportSecurityClientOptionsAreDefault(const AOptions): Boolean;
function TransportSecurityServerFailureReason: string;
```

SChannel client handshake failures name the stage and the last
`SECURITY_STATUS` (hex and symbolic name), including whether SChannel
reported `SEC_I_INCOMPLETE_CREDENTIALS` for a certificate request.
`TransportSecurityServerFailureReason` describes the calling thread's most
recent server-side handshake failure (the SChannel status or the OpenSSL
error and peer-verification result) so feed/drain server owners can log why
a handshake ended. Neither carries key material or plaintext.

`ValidateTransportSecurityClientOptions` opens no socket and persists
nothing, so callers can reject a bad configuration before connecting.
HTTPClient calls it before the first dial. It refuses:

- anchors-only trust without anchors;
- `InsecureSkipVerify` combined with anchors or anchors-only trust;
- a passphrase without an identity, and a passphrase with an embedded NUL;
- anchors over 4 MiB or 1,024 certificates, and identities over 16 MiB (the
  server's PKCS#12 ceiling);
- anchors that are neither PEM `CERTIFICATE` blocks nor one complete DER
  certificate;
- any anchor the platform cannot parse as a certificate, a PKCS#12 bundle
  the platform cannot open with the given passphrase, and, on Windows, a
  bundle that holds more than one certificate with a private key.

The unit removes the PEM armour and decodes the base64 body, and checks that
each result is one complete DER `SEQUENCE`. The platform then parses it:
OpenSSL builds a throwaway context with the anchors and the identity,
Secure Transport runs the connection's own importers (the identity check
creates and removes a temporary keychain), and SChannel parses the anchors
into a memory store and opens the bundle with `PKCS12_NO_PERSIST_KEY`, so
no key is persisted. Every backend also parses the anchors and imports the
identity before its first handshake byte, so a caller that skips validation
still never sends TLS traffic with malformed material. Certificate parsing
and all path validation stay with each platform's API. No certificate
semantics or cryptography are implemented in LWPT.

Anchors are root CA certificates. A non-self-signed CA certificate used as an
anchor is accepted by Secure Transport, but OpenSSL (without
`X509_V_FLAG_PARTIAL_CHAIN`) and the Windows exclusive-root engine (without
`CERT_CHAIN_EXCLUSIVE_ENABLE_CA_FLAG`) require the chain to reach a
self-issued anchor. LWPT does not set either flag, so only roots are portable.

### Trust anchors per backend

| Backend | Anchors only | System plus anchors | Host name |
| --- | --- | --- | --- |
| OpenSSL | Anchors are added to the context store with `X509_STORE_add_cert`; default paths are not loaded. | `SSL_CTX_set_default_verify_paths`, then the anchors are added to the same store. One evaluation. | `SSL_set1_host`, as today. |
| Secure Transport | `kSSLSessionOptionBreakOnServerAuth` pauses the handshake. The peer `SecTrust` gets an SSL policy for the host, `SecTrustSetAnchorCertificates`, and `SecTrustSetAnchorCertificatesOnly(true)`, then `SecTrustEvaluateWithError`. | Same, with `SecTrustSetAnchorCertificatesOnly(false)`. One native evaluation. | The SSL policy's host name. |
| SChannel | `SCH_CRED_MANUAL_CRED_VALIDATION`. After the handshake, `CertGetCertificateChain` runs in an engine whose `hExclusiveRoot` is an in-memory store of the anchors, then `CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL)`. | The default engine is tried first. If it fails, the exclusive-anchor engine is tried. Either success accepts. Two evaluations. | The SSL policy's `pwszServerName`. |

The asymmetry on Windows matters in one case. A chain that needs a system
root and an anchor-only intermediate at the same time is not a union the
two-pass check can build. That is acceptable because anchors are roots.

The failure message names verification on every backend:
`TLS certificate verification failed: <reason>`. OpenSSL reports the
`X509_verify_cert_error_string`, macOS the `CFError` code, and Windows the
policy `HRESULT`. On OpenSSL the options path sets `SSL_VERIFY_PEER` on the
context before `SSL_new`, so a failed verification aborts the handshake
before a client certificate or any application data is sent. The option-less
path keeps its historical post-handshake check unchanged. On Windows the
check runs after SChannel completes the handshake, so a client certificate
has already been sent when an untrusted server is rejected. It runs before
any application data.

Options that set neither anchors nor insecure mode leave each platform's
default server evaluation in charge, exactly as without options. This covers
an identity-only configuration.

### Client identity

| Backend | Import | Lifetime |
| --- | --- | --- |
| OpenSSL | `PKCS12_parse` from memory, then `SSL_CTX_use_certificate`, `SSL_CTX_use_PrivateKey`, chain certificates, and `SSL_CTX_check_private_key`. | Owned by the connection's `SSL_CTX`; input copies and the passphrase are wiped. |
| Secure Transport | The server importer: an isolated 0600 temporary keychain, never added to the search list, then `SSLSetCertificate` with the identity and its chain. | Released when the connection closes, with the same quarantine and dead-owner recovery rules as server snapshots. |
| SChannel | The server importer: `PFXImportCertStore` into the user's CNG provider, persisted because SChannel signs in lsass, then passed as `paCred`. The bundle's intermediates are published into the current user's intermediate store, as for a server, because SChannel builds the outgoing client `Certificate` message from the Windows stores. | The connection owns the container and deletes it with `NCryptDeleteKey` when it closes, and withdraws the issuers it published. A hard kill can leave both behind, as for server snapshots. |

`PFXImportCertStore` persists one container for every certificate with a
key, not only the selected one. The importer therefore records every
container before anything can fail, deletes them all on every exit
(including rejection), and rejects a bundle with more than one keyed
certificate. The rule applies to server contexts too, which share the
importer. OpenSSL and Secure Transport keep no persistent key outside the
connection, so they use the first identity as before.

The client identity is not validated as a server identity (`tsivPermissive`).
Judging it is the server's job. With options, SChannel sets
`SCH_CRED_NO_DEFAULT_CREDS` so it never picks a certificate from the user's
store by itself. If a server asks for a certificate and none was supplied,
the client continues anonymously (`ISC_REQ_USE_SUPPLIED_CREDS`), as OpenSSL
and Secure Transport do, and the server decides.

### Insecure mode

`InsecureSkipVerify` is named after the well-known Go field so that it reads
as a warning at every call site. It uses `SSL_VERIFY_NONE` without
`SSL_set1_host` on OpenSSL. On macOS it breaks on server authentication and
resumes without evaluating. On Windows it uses manual validation and skips
the check. The connection is still encrypted, and the peer certificate is
still readable, but the peer is not authenticated. The guardrails:

- It is never the default, and nothing in LWPT's own commands sets it.
- It cannot be combined with trust anchors, because a caller who has anchors
  should use them.
- In HTTPClient it applies only to the configured origin, like every other
  TLS option.

### Peer certificate

`TransportSecurityPeerCertificate` returns the DER of the peer's leaf on an
active client connection, with or without options. It uses
`SSL_get1_peer_certificate` (falling back to `SSL_get_peer_certificate` on
OpenSSL 1.1) with `i2d_X509`, `SSLCopyPeerTrust` with
`SecTrustGetCertificateAtIndex(0)` and `SecCertificateCopyData`, or
`QueryContextAttributes(SECPKG_ATTR_REMOTE_CERT_CONTEXT)`. It returns empty
bytes for an inactive or server connection. Subject and SAN parsing are left
to the caller, so the package exposes no certificate parser.

### HTTPClient

`THTTPRequestOptions.TLS` carries the record. `DefaultHTTPRequestOptions`
sets it to the zero value, and `ValidateRequestOptions` checks it before any
connection. The options apply to every `https` hop whose scheme, host (case
insensitively), and port equal the initial URL's. Any other origin connects
with the default client. A client certificate, a private anchor, or an
insecure exemption therefore never follows a redirect to another authority.
The destination policy, the redirect budget, and the rest of redirect
handling are unchanged.

### Test seam

Exercising mTLS needs a server that requests a certificate. The production
server never does, and this ADR does not change that. The test-only
`TransportSecurityTestRequireClientCertificate` exists only when `PRODUCTION`
is not defined. It makes one fresh server connection require a certificate
that chains to caller-supplied client anchors for client authentication.
Intermediates must arrive in the client's `Certificate` message: OpenSSL
uses a connection-private verify store holding only the anchors with
`SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`; Secure Transport uses
`kAlwaysAuthenticate`, breaks on client authentication, and evaluates with
the client SSL policy, the anchors only, and network fetching disabled;
SChannel adds `ASC_REQ_MUTUAL_AUTH`, builds the chain in an
exclusive-anchor engine with AIA disabled, and refuses a chain that used any
intermediate absent from the certificates the client sent (the remote
certificate's store). That last check is explicit rather than an engine
restriction, because the client's own published intermediates sit in the
same user's store on a single test machine. The test client identity uses its own root and intermediate, so
a client that omits its bundled intermediate is refused. The loopback
E2E suite `packages/httpclient/tests/e2e/TransportSecurityClientOptions.E2E.Test.pas`
drives the production client against these server backends on every
platform.

## Considered options

- **Keep `SSL_CERT_FILE` as the private-CA mechanism.** Rejected. It is
  process-wide, it works only on OpenSSL, and it cannot express anchors-only
  trust.
- **Import anchors into the user's trust store on Windows and macOS.**
  Rejected. It persists state outside the process, may prompt, and would
  change trust for every other program.
- **Merge system roots and anchors into one Windows store.** Rejected.
  Copying the system roots into a custom engine loses Windows' own root
  updates and policy, and the two-pass check keeps each evaluation native.
- **Validate the client identity like a server identity.** Rejected. The
  purpose and chain checks describe server certificates, and the peer is the
  authority on what it accepts.
- **Carry TLS options across every redirect.** Rejected. A client
  certificate or insecure exemption must not reach an authority the caller
  never named.
- **Expose subject and SANs instead of DER.** Rejected for now. DER is
  lossless and enough for pinning. Parsing it would add certificate code the
  package does not otherwise need.

## Consequences

- duetto and other consumers can trust a private CA, present a client
  certificate, and pin the peer on all three platforms without environment
  variables.
- ADR-0016's statement that all clients verify the peer and host name now
  holds unless a caller sets `InsecureSkipVerify`.
- On Windows, a connection with a client identity writes and deletes a CNG
  key container, and anchor trust costs one or two extra chain evaluations
  per handshake.
- On macOS, a connection with a client identity creates and removes a
  temporary keychain, as a server context does.
- The HTTPClient package version moves to 0.7.0. `THTTPRequestOptions` gains
  a field, and HTTPClient's interface now uses `TransportSecurity`.
- OCSP and CRL policy, ALPN, and SNI override remain out of scope.
