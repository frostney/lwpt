# Deployment

Platform support tiers, the per-platform TLS backend story, the release process, the macOS quarantine workaround, and the codesigning policy for v1.

## Executive Summary

- **Six release targets** map to the matrix in [`docs/ci.md`](./ci.md): `aarch64-darwin` + `x86_64-darwin` + `x86_64-linux` + `aarch64-linux` + `x86_64-win64` + `i386-win32`. All six tested natively on every push to `main` (per `ci.yml`); all six published per release tag (per `release.yml`).
- **TLS is platform-native in both directions on Windows and macOS.** Clients use SChannel on Windows, Secure Transport on macOS, and OpenSSL on Linux per [ADR-0016](./adr/0016-tls-backend-per-platform.md). Server accept uses native SChannel on Windows per [ADR-0033](./adr/0033-schannel-server-tls-accept-on-windows.md), runtime-loaded OpenSSL on Unix-not-Darwin per [ADR-0024](./adr/0024-openssl-server-tls-accept.md), and two native Apple implementations on macOS: Network.framework by default on macOS 26 and newer, and the HTTPClient Secure Transport backend on macOS 15 and older per [ADR-0043](./adr/0043-self-hosted-registry-origin.md).
- **Windows has no OpenSSL relationship at all.** Neither direction links, loads, or requires OpenSSL, so Windows server consumers have no DLL prerequisite and `i386-win32` supports server accept like every other target.
- **The three Windows CI guards fail closed on OpenSSL linkage.** They inspect normal and delay imports, imported symbol families regardless of DLL name, and static-link inputs; canaries prove the parser sees both a prohibited fixture and real system imports.
- **No codesigning for v1.** macOS users see the "unidentified developer" warning; documented workaround is `xattr -d com.apple.quarantine ./lwpt`. Promote to Apple Developer ID + notarisation only on demonstrated demand.
- **Release artefacts come from CI.** Tag → `release.yml` → cross-build on macos-latest → package → GitHub Releases. No hand-built releases; ever.

## Platform tier matrix

| Tier | Targets | What "supported" means |
|------|---------|------------------------|
| **Tier 1** | `x86_64-linux`, `aarch64-linux`, `x86_64-win64`, `aarch64-darwin`, `x86_64-darwin` | Full LWPT self-test on every push to `main` (`ci.yml` runs the repository's ordinary and E2E path selectors natively on each without repeating programs). Pre-built binaries published per release tag. |
| **Tier 1 (build + smoke)** | `i386-win32` | Cross-built + tested on a `windows-latest` runner alongside `x86_64-win64`. The 32-bit binary is published per release. |
| **Tier 2** | Other Win64 SKUs (server, arm64) | CI is x86_64 only at the Windows runner level; arm64-windows would need separate runners. |
| **Tier 3** | FreeBSD, OpenBSD, Linux ARM32, NetBSD, others | Documented as "should work, no automation". Issues accepted but not blocking. No published binaries. PRs to elevate to Tier 1 welcome. |

The Tier 1 set matches the six-target cross-build matrix in `toolchain.yml` + `ci.yml` + `release.yml`. If a real user need elevates a Tier 2 / Tier 3 platform, edit this file, the workflows, and the toolchain's `CACHE_VERSION` together.

## TLS backends per platform

Per [ADR-0016](./adr/0016-tls-backend-per-platform.md), [ADR-0024](./adr/0024-openssl-server-tls-accept.md), and [ADR-0033](./adr/0033-schannel-server-tls-accept-on-windows.md), `TransportSecurity.pas` ([`packages/httpclient/source/TransportSecurity.pas`](../packages/httpclient/source/TransportSecurity.pas)) deliberately selects different backends for peer-verifying clients and certificate-presenting servers:

| Platform | Outbound client | Server accept | Runtime prerequisite |
|----------|-----------------|---------------|----------------------|
| **Windows** | SChannel | SChannel (SSPI + crypt32), built in | None |
| **macOS** | Secure Transport | Secure Transport at the HTTPClient seam; the registry selects Network.framework on macOS 26+ and Secure Transport on macOS 15 and older | None |
| **Linux + other Unix** | OpenSSL, runtime-loaded | OpenSSL 3+, runtime-loaded | Distro's libssl package — see "Linux" below |

`HTTPClient` consumes the blocking `StartTransportSecurity` surface for outbound connections. Fd-owning servers create one `TTransportSecurityServerContext` from caller-supplied PKCS#12 bytes plus a passphrase; the byte input is copied, parsed synchronously, and wiped. The convenience path overload walks every component without following symbolic links or reparse points, retains the validated parent handles until the final file is open, reads through that final handle, then delegates to the byte API. Strict validation is the default: the leaf and bundled chain must be currently valid, the leaf must explicitly support server authentication and must not assert `CA:TRUE` (basic constraints may be absent), every bundled issuer must assert `CA:TRUE`, permit certificate signing when key usage is present, and satisfy its path-length constraint, and every bundled link must have coherent names and signatures. The `issuer-no-certsign` fixture is rejected because its key-usage extension omits `keyCertSign`. This policy validates the supplied identity, not platform system trust. Self-signed development identities require explicit `tsivPermissive` validation.

Contexts expose the same byte and path inputs through `Reload`. A replacement is completely parsed and validated before an atomic swap. Each accepted connection retains an immutable reference-counted snapshot, so an old identity remains alive until its last connection closes; a failed reload leaves the current snapshot active. The listener must stop and join all paths that can call `BeginTransportSecurityServer` or `Reload` before closing the context holder; established connections may continue through their retained snapshots. `BeginTransportSecurityServer` gives each connection a capacity-gated read memory BIO and bounded write-side memory BIO pair. Encrypted-input and encrypted-output capacities are independent: each defaults to 64 KiB and is configurable from 17–256 KiB; input also uses a configurable low watermark that defaults to half. `TransportSecurityFeedCiphertext` accepts only the prefix that fits, while `TransportSecurityServerInputFlow` exposes buffered, accepted, and consumed counts plus hysteretic backpressure. `TransportSecurityServerOutputFlow` exposes exact capacity, pending bytes, and remaining bytes across retained output and the BIO. `Active` remains false until the handshake authenticates. The transport feeds receive completions, steps one operation at a time, and drains the retained ciphertext queue before any later protocol operation. Returned ciphertext spans remain stable until consumed, and WANT-write plaintext is retained inside the connection for a nil, zero-length resume call. Reads distinguish peer `close_notify` as `tssPeerClosed`. Graceful close queues `close_notify`; abortive or fatal close discards TLS state. Neither path owns or closes the transport socket. The socket owner **must** start a monotonic handshake deadline after `BeginTransportSecurityServer` and count every socket-read ciphertext byte against its handshake budget before feeding the accepted prefix. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT is the canonical source for this package.

### Outbound HTTP resource policy

The general-purpose `HTTPClient` API applies conservative defaults to every
request: a 64 MiB response-body limit, a 64 KiB response-header limit, and a
120-second whole-request deadline. `THTTPRequestOptions` lets an embedding
application select tighter or larger positive bounds without replacing the
default overloads. Fixed-length, chunked, and close-delimited bodies all use
the same body budget. A fixed-length response is accumulated only as bytes
arrive; its remote `Content-Length` is validated before any body allocation,
and negative, overflowing, conflicting, over-limit, or truncated lengths fail
with `EHTTPError`.

The deadline is monotonic and shared by connect, TLS handshake, request send,
response headers, response body, and redirects. It is independent of per-read
idleness, so periodic slow bytes do not reset it. The same contract wraps
SecureTransport, OpenSSL, and SChannel while retaining each backend's existing
certificate-chain and hostname checks. System DNS resolution remains
synchronous; if it returns after the deadline, the request fails immediately
before connecting.

LWPT's archive fetcher deliberately opts into a 256 MiB body budget and a
300-second deadline because dependency archives are larger and slower than a
typical general-purpose HTTP response. Header limits retain the package
default. HTTP-layer failures are wrapped as `EFetchError` with the requested
URL, preserving install transaction cleanup and diagnostics.

### Windows: SChannel clients and SChannel servers

Outbound HTTPS calls into Windows' Security Service Provider Interface (SSPI) directly via the `Windows` unit and the SChannel constants in `TransportSecurity.pas`. Running LWPT as a client therefore has no third-party DLL prerequisite. The Windows release archive contains exactly:

```text
lwpt-<version>-windows-x64.zip
└── lwpt-<version>-windows-x64/
    ├── lwpt.exe
    ├── README.md
    ├── CONTEXT.md
    ├── CONTRIBUTING.md
    ├── AGENTS.md
    └── docs/
        ├── quick-start.md
        ├── architecture.md
        └── build-system.md
```

Server accept has the same story per [ADR-0033](./adr/0033-schannel-server-tls-accept-on-windows.md): `AcceptSecurityContext` from `secur32.dll` terminates TLS and `crypt32.dll` imports the PKCS#12 identity, both operating-system components. The private key is imported into the invoking user's CNG key-storage provider (`PKCS12_ALWAYS_CNG_KSP | CRYPT_USER_KEYSET`) because SChannel runs server key operations in lsass and cannot use an ephemeral in-process key; each identity snapshot owns its container and deletes it via `NCryptDeleteKey` when its last reference is released. The bundle's intermediates are published into the current user's Intermediate Certification Authorities store for as long as the snapshot lives and withdrawn when it is released, because SChannel builds the outgoing certificate flight from the Windows stores rather than from an in-process one. Each snapshot adds and owns an exact duplicate store entry, so retiring one snapshot cannot withdraw another snapshot's issuer or a user-installed entry. Nothing is ever written to a root store, and the credential is built from the caller's bundle alone rather than from the Windows trust store. A hard kill can leave the snapshot's CNG key container and non-root issuer entries behind; ordinary teardown and reload remove them. On Windows 10 version 1809 / Server 2019 and newer, `SCH_CREDENTIALS` version 5 disables protocols below TLS 1.2 while leaving the ceiling to SChannel, so Windows 11 / Server 2022 and newer can negotiate TLS 1.3. Older supported hosts use `SCHANNEL_CRED` version 4 pinned to TLS 1.2. LWPT no longer import-links, runtime-loads, or requires OpenSSL anywhere on Windows.

#### CI guard

`pr.yml`, `ci.yml`, and `release.yml` each parse the normal and delay PE import directories, reject imported OpenSSL symbol families regardless of the DLL filename, and inspect linker-map/archive inputs for static OpenSSL. Matching happens inside the checker, so a missing or failing `grep` cannot be interpreted as clean. A small PE fixture with a prohibited import is the positive detection canary. The real binary must expose at least one known system import, so a parser regression that returns zero imports also fails. Runtime-loader strings remain allowed because they are not linkage.

### macOS: Secure Transport and Network.framework (no Homebrew dependency)

The `Darwin` client branch of `TransportSecurity.pas` calls into Apple's SecureTransport framework, which is built into every macOS install. No `brew install openssl@3`, no `DYLD_LIBRARY_PATH` shenanigans, no library version pinning. macOS release archives ship the binary alone, same shape as the Windows archives (without the `.exe` suffix).

Darwin implements `TTransportSecurityServerContext` with the public Secure
Transport server API and the same feed/drain state-machine contract used by
the other native backends. The size-bounded PKCS#12 identity is imported into
an isolated 0600 temporary keychain, validated against its bundled private
anchor with Apple's SSL server policy, and retained by immutable connection
snapshots. The import never changes the current user's default keychain or
search list; ordinary abort, close, reload retirement, and context teardown
delete the temporary keychain. A later context creation performs a bounded
scan and recovers an exact same-user regular-file residue only after its owner
PID is definitely dead; links, foreign files, and live-owner files are left
untouched.

The self-hosted registry keeps its Network.framework listener as the default
on macOS 26 and newer. On macOS 15 and older it selects the portable registry
socket listener, which delegates TLS to the HTTPClient Secure Transport server
backend and therefore shares the same request parsing, routing, resource, and
shutdown behavior as Windows and Unix. The selector reads the runtime macOS
product-version major through public Foundation APIs; CPU architecture has no
role. Neither Darwin path links or loads OpenSSL.

#### Quarantine workaround

macOS marks downloads from GitHub Releases with the `com.apple.quarantine` extended attribute. On first run, Gatekeeper blocks execution. The fix:

```sh
xattr -d com.apple.quarantine ./lwpt
```

…then run normally. Documented in [`quick-start.md`](./quick-start.md) and reiterated in every macOS release note.

#### Codesigning policy (v1)

**Not signed.** v1 ships with the quarantine workaround documented. The arguments for and against:

- **Pro:** professional signed binary; no quarantine; Gatekeeper-friendly.
- **Con:** Apple Developer ID ($99/yr), notarisation roundtrip per release (10-30 min CI extension), key management.

The judgement is that the user base in v1 is small enough that the quarantine workaround is acceptable. Revisit when a real user explicitly asks. The workaround is one line; codesigning is a permanent operational obligation.

### Linux: system OpenSSL

The `Unix`-and-not-`Darwin` branch of `TransportSecurity.pas` loads the system shared object at runtime via `DynLibs.LoadLibrary` against standard names (`libssl.so.3` / `libcrypto.so.3` and client-compatible fallbacks). The same loaded interface serves outbound clients and the socket-independent memory-BIO server API, but server context construction rejects a runtime older than OpenSSL 3. Users need their distro's libssl package:

- Debian / Ubuntu: `apt install libssl3`
- Fedora / RHEL: `dnf install openssl-libs`
- Alpine: `apk add openssl3-libs`
- Arch: `pacman -S openssl`

The library is almost always already installed (most distros pull it in transitively via `curl`, `git`, `wget`, etc.). When packaging for a specific distro (`.deb`, `.rpm`), declare the libssl package as a runtime dependency. The release archive for Linux is a plain `.tar.gz` of the binary + docs; distro packages are a separate, non-v1 workstream.

If `lwpt install` fails with `HTTPS requires OpenSSL but it could not be loaded`, the distro's libssl package is missing or the binary's `dlopen` could not find it. Install the package; LWPT does not bundle a fallback.

## Release process

1. **Release PR.** Create `release/<version>` from green `main`, run `git-cliff --tag <version> -o CHANGELOG.md`, bump `[package].version`, regenerate `source/Version.inc`, validate, and open a draft PR titled `chore(release): <version>`.
2. **Squash-merge the PR.** The merge commit on `main` must already contain the changelog and version bump. Use the squash message `chore(release): <version>`.
3. **Tag the merge commit.** `git tag -a 0.1.0 -m 0.1.0` on the post-merge `main` commit (no `v` prefix — SemVer 2.0.0 canonical form per [ADR-0009](./adr/0009-source-syntax-and-tag-resolution.md); `v0.1.0` is also accepted by `release.yml` as a courtesy). Pre-release tags use the `0.1.0-rc.1` form (auto-detected by `release.yml` and published as `prerelease: true`).
4. **`release.yml` triggers.** Mirrors `ci.yml`'s cross-build matrix exactly
   (same flag set, same toolchain cache key). The publish job then waits at the
   protected `release` environment for explicit approval.
5. **GitHub Release published by CI.** After approval, the workflow packages
   each target as `tar.gz` (Unix) / `zip` (Windows), generates a SHA-256
   checksums file, and extracts release notes from the committed `CHANGELOG.md`
   section for the tag. Never create the GitHub Release manually. Archive
   naming:

   ```text
   lwpt-<version>-macos-arm64.tar.gz
   lwpt-<version>-macos-x64.tar.gz
   lwpt-<version>-linux-x64.tar.gz
   lwpt-<version>-linux-arm64.tar.gz
   lwpt-<version>-windows-x64.zip
   lwpt-<version>-windows-x86.zip
   lwpt-<version>-checksums.txt
   ```

6. **Install scripts** at `scripts/install.sh` (Linux/macOS) + `scripts/install.ps1` (Windows) point at the GitHub Releases asset URLs; both download the per-platform archive + checksums file and verify SHA-256 before installing.

There are no hand-built release artefacts. If `ci.yml` is broken at tag time, fix it first (the `ci.yml` push-to-main run validates the same flag set + matrix that `release.yml` uses).

## Hotfix releases

For an urgent CVE in an LWPT-canonical package or in a system TLS backend on Linux:

1. Patch on `main` with the fix + a `*.Test.pas` proving the fix.
2. Tag the patch version (`0.1.1`) — go straight from `0.1.0` to `0.1.1`, no pre-release.
3. The release notes name the CVE explicitly so downstream users can audit.

TLS on Windows (SChannel, both directions) and macOS (SecureTransport) is updated by the OS vendor. Linux OpenSSL CVE responses belong to the runtime provider; LWPT loads that library but does not ship it.

## Self-hosted runners (Tier 3 path)

Tier 1 / Tier 2 use GitHub-hosted runners (free for public repos; the platforms above are all supported on hosted runners as of 2025). Promoting a Tier 3 platform (FreeBSD, NetBSD, Linux ARM32) to Tier 1 requires a self-hosted runner — practical but a permanent operational cost. Not in scope for v1.
