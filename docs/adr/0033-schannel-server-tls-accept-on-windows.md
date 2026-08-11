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
- **Private keys never touch the user's key store.** The PKCS#12 bundle is
  imported with `PKCS12_NO_PERSIST_KEY | PKCS12_ALWAYS_CNG_KSP`, so the key is
  ephemeral and in-memory for the lifetime of the credential snapshot.

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
behave the same.

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

`SEC_I_RENEGOTIATE` is treated as a fatal protocol error: the connection is
poisoned and `tssError` returned. This is deliberate parity, not an omission.
The OpenSSL backend sets `SSL_OP_NO_RENEGOTIATION` and fails
`SSL_read` when a peer attempts renegotiation, so refusing it identically keeps
one observable outcome instead of introducing a Windows-only renegotiation
path that consumers would have to handle.

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
neither mode consults the Windows system trust store: `SCHANNEL_CRED` is built
from the caller's bundle alone.

### Protocol floor

`SCHANNEL_CRED` (structure version 4) is used rather than `SCH_CREDENTIALS`
(version 5) because it is declarable by hand next to the client-side SSPI
declarations already in the unit and is available on every supported Windows
version. It tops out at TLS 1.2, so `grbitEnabledProtocols` is pinned to
`SP_PROT_TLS1_2_SERVER`. That reproduces the OpenSSL backend's TLS 1.2 floor
exactly rather than merely bounding it from below. Raising the ceiling to
TLS 1.3 is a follow-up that requires `SCH_CREDENTIALS` and a Windows 11 /
Server 2022 floor.

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
  close, and peer-close cases on Windows. The Windows legs therefore exercise
  the shipped Windows backend for the first time, on both win64 and win32.
- ADR-0024 remains the canonical description of the server contract. This ADR
  supersedes only its Windows backend selection and its Windows OpenSSL
  prerequisite.
