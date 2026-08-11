# Native SChannel terminates server TLS on Windows

## Executive Summary

- **Windows server accept is native SChannel.** `AcceptSecurityContext` plus
  crypt32 identity handling replaces the runtime-loaded OpenSSL 3 server
  backend that [ADR-0024](./0024-openssl-server-tls-accept.md) introduced.
  Unix-not-Darwin keeps memory-BIO OpenSSL; Darwin keeps Network.framework.
- **Windows now has no OpenSSL relationship at all.** The client was already
  SChannel per [ADR-0016](./0016-tls-backend-per-platform.md), so removing the
  server backend removes the last consumer. `TRANSPORT_SECURITY_OPENSSL` is now
  defined only for Unix-not-Darwin, and the Windows build compiles no OpenSSL
  binding, loads no DLL, and needs no administrator-provisioned runtime.
- **win32 gains server TLS for the first time.** No 32-bit OpenSSL 3 build was
  available, so `i386-win32` previously had no server accept at all. SChannel
  is an operating-system component and is equally available on both Windows
  architectures.
- **The public contract is unchanged.** Every observable behaviour of
  ADR-0024 — the state machine, accepted-prefix input admission with
  high/low-watermark hysteresis, exact pending/remaining output accounting,
  retained WANT-write plaintext, stable retained-ciphertext spans, strict and
  permissive identity validation, immutable reference-counted reload
  snapshots, and `tssPeerClosed` — is reproduced rule for rule.
- **The private key is persisted, owned, and deleted with its snapshot.**
  SChannel performs server key operations in lsass, which cannot reach an
  in-process ephemeral key, so an ephemeral import is not an option. Each
  snapshot owns one persisted CNG container and deletes it when its last
  reference goes away.

## Context

ADR-0024 chose memory-BIO OpenSSL for server accept because the seam has to be
socket-independent: duetto's IOCP transport owns an overlapped socket that
cannot be handed to a library that wants a file descriptor. That argument was
about *sockets*, not about OpenSSL — and SSPI is equally socket-independent,
because `AcceptSecurityContext`, `EncryptMessage`, and `DecryptMessage` all
operate on caller-owned buffers.

The OpenSSL choice carried three costs on Windows:

1. A deployment prerequisite. Windows server consumers had to provision
   OpenSSL 3 DLLs into an administrator-controlled directory covered by the
   restricted `LoadLibraryEx` search, for a platform whose TLS stack ships
   with the operating system.
2. No win32 support. There is no maintained 32-bit OpenSSL 3 distribution to
   point users at, so `i386-win32` shipped without server TLS.
3. Untested Windows CI. The Windows test legs install no OpenSSL, so the whole
   TLS-server suite was skipped there. The backend that Windows shipped was
   only ever exercised on Linux.

## Decision

Add `TSB_SCHANNEL_SERVER` as a fourth backend and select it for
`{$IFDEF MSWINDOWS}`. Define `TRANSPORT_SECURITY_OPENSSL` only for
Unix-not-Darwin. Introduce `TRANSPORT_SECURITY_SERVER` for the code both
server backends share — the 16 MiB PKCS#12 ceiling, the link-refusing and
reparse-point-refusing identity-file loader, and the connection/secret
bookkeeping — so that code is no longer implicitly owned by the OpenSSL
backend.

### Mapping the OpenSSL contract onto SSPI

Two mechanical differences exist; neither is observable through the public API.

**Buffered ciphertext.** OpenSSL parks unconsumed ciphertext in its read BIO
and `BIO_pending` is what the flow counters read. SChannel has no such buffer,
so the backend keeps one: `TransportSecurityFeedCiphertext` appends an accepted
prefix to it, and the `SECBUFFER_EXTRA` leftovers reported by
`AcceptSecurityContext` and `DecryptMessage` are written back into it. That is
what makes `ConsumedBytes = AcceptedBytes - BufferedBytes` hold identically on
both backends, and what makes the caller's re-offer of the unaccepted remainder
behave the same. Because `DecryptMessage` returns in-place plaintext and extra
spans into that owned buffer, the backend copies every plaintext span before
replacing the buffer with its preserved ciphertext tail.

**Output granularity.** OpenSSL writes records straight into a
capacity-sized BIO pair and will happily leave a record split across the
capacity boundary, so a saturated output queue holds exactly `OutputCapacity`
bytes. `EncryptMessage` produces whole records and `AcceptSecurityContext`
whole tokens. The backend therefore stages one record or token at a time and
queues as much of it as fits, retaining the tail until capacity frees up.
Pending output is still exactly `OutputCapacity` when saturated, and
`TransportSecurityServerWrite` still reports `BytesProcessed` only once the
entire caller buffer has been encrypted and queued — 0 with `tssWantWrite`
until then, exactly like a partially completed `SSL_write`. Handshake and
shutdown tokens use the same staging path, so a certificate flight larger than
`OutputCapacity` drains incrementally rather than failing the connection,
which is what OpenSSL's bounded write BIO does.

### Renegotiation

TLS 1.2 renegotiation is treated as a fatal protocol error: the connection is
poisoned and `tssError` returned. This preserves parity with the OpenSSL
backend, which sets `SSL_OP_NO_RENEGOTIATION`. TLS 1.3 uses
`SEC_I_RENEGOTIATE` for protocol-required post-handshake messages rather than
legacy renegotiation, so those messages re-enter the SChannel handshake state
machine as described below.

### Identity validation

`tsivStrict` is ported rule for rule to crypt32: `CertVerifyTimeValidity` for
validity windows, `CertCompareCertificateName` for self-issued detection and
issuer linking, `CryptDecodeObjectEx(X509_BASIC_CONSTRAINTS2)` for CA and
path-length constraints, `CertGetIntendedKeyUsage` for `keyCertSign` and the
server-purpose key-usage rejection, `CertGetEnhancedKeyUsage` for the
`serverAuth` requirement, and `CryptVerifyCertificateSignatureEx` for the
chain-coherence, root-signature, and cycle checks. The chain is the imported
store minus the leaf, and the search-based linking algorithm — including
ambiguous-issuer and path-length rejection — is the same one the OpenSSL
backend runs. Error messages are byte-identical so consumers and tests do not
have to branch on platform.

One documented gap: OpenSSL additionally rejects a certificate carrying an
unhandled critical extension (`EXFLAG_CRITICAL`) or an invalid policy encoding
(`EXFLAG_INVALID_POLICY`). crypt32 exposes no equivalent aggregate flag, so
those two sub-cases are not reproduced. Everything ADR-0024 pins is enforced.

`tsivPermissive` remains an explicit self-signed development option, and
neither mode consults the Windows system trust store: the SChannel credential
is built from the caller's bundle alone.

### Private key lifetime

The first Windows CI run settled a question the design had guessed wrong.
Importing with `PKCS12_NO_PERSIST_KEY | PKCS12_ALWAYS_CNG_KSP` produces an
ephemeral in-process key, and `AcquireCredentialsHandle` then fails with
`SEC_E_NO_CREDENTIALS` (0x8009030E). This is inherent, not a flag mistake:
SChannel runs server key operations in lsass, which cannot reach a key that
only exists inside the calling process. (.NET raises the equivalent failure
for `X509KeyStorageFlags.EphemeralKeySet` with `SslStream`, for the same
reason.)

The bundle is therefore imported with `PKCS12_ALWAYS_CNG_KSP |
CRYPT_USER_KEYSET` into the user's CNG key-storage provider, and the snapshot
takes ownership of the resulting container: immediately after import it claims
the key handle with `CryptAcquireCertificatePrivateKey`
(`CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG | CRYPT_ACQUIRE_SILENT_FLAG`), refusing
the identity outright if the handle is not caller-owned or not a CNG key —
better to fail than to hold a container nothing will clean up. Every teardown
path funnels through the snapshot's `Release`, which calls `NCryptDeleteKey`
at the last reference. Because deletion is tied to the refcount rather than to
`Reload`, a snapshot that has been reloaded away keeps its container until the
last connection still using it finishes.

**Container naming is the load-bearing detail.** Two snapshots built from the
same bundle must own different containers, or releasing one would delete a key
the other is still serving with. `PFXImportCertStore` names CNG keys itself
rather than honouring a name carried in the bundle, so ordinary bundles get a
fresh container per import. The design does not rest on that being true: the
container name is read back from `CERT_KEY_PROV_INFO_PROP_ID` and a Windows
test asserts that two concurrently live contexts built from one fixture report
different names, that closing the first leaves the second able to handshake,
and that a reload publishes a new container while the retained snapshot keeps
serving with the old one. `PKCS12_ALLOW_OVERWRITE_KEY` is deliberately not
passed, so a bundle that did carry an already-existing container name fails
the import loudly instead of silently overwriting a live key.

**Accepted cost:** a hard kill between import and deletion leaks one container
in the user's CNG key store (`%APPDATA%\Microsoft\Crypto\Keys`). Ordinary
operation — including repeated reloads — deletes each container as its
snapshot is released, so this is bounded by abnormal termination rather than
by uptime.

### Delivering the bundled chain

The second Windows CI round settled another guess. SChannel assembles the
outgoing Certificate flight itself, and it builds that chain from the Windows
certificate stores rather than from the caller's in-memory store — the
handshake runs outside the calling process, so a store that only exists in
this process is invisible to it. A PKCS#12 bundle carrying an intermediate
therefore produced a leaf-only flight even though the intermediate was in the
imported store, was reachable through the leaf's `hCertStore`, and satisfied
strict chain validation. .NET meets the same wall: `SslStream` sends only the
leaf unless the intermediates are in a Windows store, which is why
`SslStreamCertificateContext` exists and why it works by adding the caller's
intermediates to the Intermediate Certification Authorities store.

Each snapshot therefore publishes its bundled issuers into the **current
user's** `CA` store while it is alive, with two deliberate differences from
.NET: the user's store rather than the machine's, so no administrative rights
are needed and nothing is published machine-wide; and every context added is
recorded and withdrawn again when the snapshot is released, where .NET leaves
them behind. `CERT_STORE_ADD_ALWAYS` gives each live snapshot an independently
owned store entry even when another snapshot or the user already has the same
certificate. Release deletes the exact context returned for that addition, so
retiring an old snapshot cannot withdraw a newer snapshot's issuer or the
user's pre-existing entry. Publication is best effort — a store that cannot be
opened or written degrades to a leaf-only flight rather than failing the
identity. A hard kill can leave these non-root duplicate entries behind just as
it can leave the snapshot's CNG key container; ordinary teardown and reload
remove each snapshot's entries. Nothing is ever written to a root store, so
trust is unaffected.

### Protocol floor and operating-system ceiling

The public floor remains TLS 1.2 and the ceiling follows SChannel capability.
Windows 10 version 1809 / Server 2019 introduced `SCH_CREDENTIALS` version 5
and `TLS_PARAMETERS`. On those and newer hosts, the server uses version 5,
explicitly disables SSL 2, SSL 3, TLS 1.0, and TLS 1.1, and leaves TLS 1.2 and
newer protocols to operating-system policy. TLS 1.3 is therefore available on
Windows 11 / Server 2022 and newer without dropping Windows 8 support.

The selection gate calls manifest-independent `RtlGetVersion`, whose API is
available on every supported host. Version 5 is selected only for Windows
build 17763 or newer; a failed query and every older build take the
`SCHANNEL_CRED` version 4 fallback pinned to `SP_PROT_TLS1_2_SERVER`. The code
does not guess from undocumented credential-acquisition failure statuses.
Compile-time size guards pin both version-5 structures on win32 and win64.

SChannel reports TLS 1.3 post-handshake messages through
`SEC_I_RENEGOTIATE`. After querying the established protocol, the server feeds
the complete `SECBUFFER_EXTRA` span modified by `DecryptMessage` back through
`AcceptSecurityContext` as `SECBUFFER_TOKEN` only for TLS 1.3. If SChannel
does not return `SECBUFFER_EXTRA`, the same modified input buffer is replayed
as Microsoft requires. The handshake call preserves any following ciphertext,
and any response token uses the same bounded output path. A TLS 1.2
renegotiation attempt remains fatal, preserving ADR-0024's no-renegotiation
contract.

## Consequences

- Windows release archives and Windows consumers have no TLS prerequisite for
  either direction. `deployment.md`'s Windows column loses its server-side
  OpenSSL row.
- The existing CI PE-import guards stay exactly as they are and keep their
  meaning: they still fail closed on any OpenSSL linkage, and `secur32.dll` and
  `crypt32.dll` were already on the system-DLL allowlist. Positive canaries now
  pin that both are accepted, so a future tightening cannot silently break the
  native path.
- `TransportSecurity.Test.pas` gates on the backend rather than the platform.
  Identity-policy, flow-configuration, and fatal-handshake coverage is
  backend-neutral and runs on every platform that has a server backend. The
  cases that need a loopback peer are split: the raw in-memory OpenSSL client
  drives them on Unix-not-Darwin, and a raw in-memory SChannel client drives
  the equivalent handshake, round-trip, flow-admission, write-retry, graceful
  close, and peer-close cases on Windows. The raw SChannel client uses the same
  adaptive credential policy and asserts the negotiated protocol ceiling;
  ordinary round-trip and close tests then exercise post-handshake TLS 1.3.
  The Windows legs exercise the shipped backend on both win64 and win32.
- ADR-0024 remains the canonical description of the server contract. This ADR
  supersedes only its Windows backend selection and its Windows OpenSSL
  prerequisite.
