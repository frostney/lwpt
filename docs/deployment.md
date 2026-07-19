# Deployment

Platform support tiers, the per-platform TLS backend story, the release process, the macOS quarantine workaround, and the codesigning policy for v1.

## Executive Summary

- **Six release targets** map to the matrix in [`docs/ci.md`](./ci.md): `aarch64-darwin` + `x86_64-darwin` + `x86_64-linux` + `aarch64-linux` + `x86_64-win64` + `i386-win32`. All six tested natively on every push to `main` (per `ci.yml`); all six published per release tag (per `release.yml`).
- **Outbound TLS stays platform-native; server accept is asymmetric.** Clients use SChannel on Windows, SecureTransport on macOS, and OpenSSL on Linux per [ADR-0016](./adr/0016-tls-backend-per-platform.md). Server accept uses runtime-loaded OpenSSL on Windows and Unix-not-Darwin per [ADR-0024](./adr/0024-openssl-server-tls-accept.md); Darwin callers get an actionable Network.framework error.
- **Windows releases still ship no OpenSSL DLLs.** SChannel clients have no prerequisite. A Windows program that consumes the server-accept interface supplies OpenSSL through the normal DLL search path.
- **The three Windows CI guards inspect the PE import table.** They reject import-linked `libssl` / `libcrypto` while allowing the DLL-name strings required by the runtime-only server loader.
- **No codesigning for v1.** macOS users see the "unidentified developer" warning; documented workaround is `xattr -d com.apple.quarantine ./lwpt`. Promote to Apple Developer ID + notarisation only on demonstrated demand.
- **Release artefacts come from CI.** Tag → `release.yml` → cross-build on macos-latest → package → GitHub Releases. No hand-built releases; ever.

## Platform tier matrix

| Tier | Targets | What "supported" means |
|------|---------|------------------------|
| **Tier 1** | `x86_64-linux`, `aarch64-linux`, `x86_64-win64`, `aarch64-darwin`, `x86_64-darwin` | Full LWPT self-test on every push to `main` (`ci.yml`'s test matrix runs `lwpt install / format --check / test / test --tier=e2e` natively on each). Pre-built binaries published per release tag. |
| **Tier 1 (build + smoke)** | `i386-win32` | Cross-built + tested on a `windows-latest` runner alongside `x86_64-win64`. The 32-bit binary is published per release. |
| **Tier 2** | Other Win64 SKUs (server, arm64) | CI is x86_64 only at the Windows runner level; arm64-windows would need separate runners. |
| **Tier 3** | FreeBSD, OpenBSD, Linux ARM32, NetBSD, others | Documented as "should work, no automation". Issues accepted but not blocking. No published binaries. PRs to elevate to Tier 1 welcome. |

The Tier 1 set matches the six-target cross-build matrix in `toolchain.yml` + `ci.yml` + `release.yml`. If a real user need elevates a Tier 2 / Tier 3 platform, edit this file, the workflows, and the toolchain's `CACHE_VERSION` together.

## TLS backends per platform

Per [ADR-0016](./adr/0016-tls-backend-per-platform.md) and [ADR-0024](./adr/0024-openssl-server-tls-accept.md), `TransportSecurity.pas` ([`packages/httpclient/source/TransportSecurity.pas`](../packages/httpclient/source/TransportSecurity.pas)) deliberately selects different backends for peer-verifying clients and certificate-presenting servers:

| Platform | Outbound client | Server accept | Runtime prerequisite |
|----------|-----------------|---------------|----------------------|
| **Windows** | SChannel | OpenSSL, runtime-loaded | None for clients; compatible OpenSSL DLLs for server consumers |
| **macOS** | SecureTransport | Unsupported; use Network.framework | None |
| **Linux + other Unix** | OpenSSL, runtime-loaded | OpenSSL, runtime-loaded | Distro's libssl package — see "Linux" below |

`HTTPClient` consumes `StartTransportSecurity` for outbound connections. Fd-owning servers create one `TTransportSecurityServerContext` from caller-supplied PEM paths, reuse it across `StartTransportSecurityServer` calls, and then use the same `TransportSecurityRead` / `TransportSecurityWrite` / `CloseTransportSecurity` connection surface. Closing TLS state never closes the caller-owned socket. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT is the canonical source for this package.

### Windows: SChannel clients, OpenSSL servers

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

The server-accept interface is separate: a Windows application that invokes it must make compatible OpenSSL DLLs available through the normal Windows loader search path. `ConfigureOpenSSLLoading` prefers the OpenSSL 3 names and retains FreePascal's older fallbacks. LWPT never import-links or ships those DLLs, and `release.yml` does not stage them.

#### CI guard

`pr.yml`, `ci.yml`, and `release.yml` each inspect the PE import table and fail only when `lwpt.exe` import-links `libssl` or `libcrypto`. The server path legitimately embeds those names for `LoadLibrary`, so a raw string scan would be a false positive. The pre-merge and release guards use `objdump -p` on their macOS cross-build runners; the native Windows test guard uses the hosted runner's GNU `objdump`. All three capture the tool output before matching, avoiding a pipefail/SIGPIPE false pass.

### macOS: SecureTransport (no Homebrew dependency)

The `Darwin` client branch of `TransportSecurity.pas` calls into Apple's SecureTransport framework, which is built into every macOS install. No `brew install openssl@3`, no `DYLD_LIBRARY_PATH` shenanigans, no library version pinning. macOS release archives ship the binary alone, same shape as the Windows archives (without the `.exe` suffix).

Server accept is intentionally unsupported on Darwin. Constructing a `TTransportSecurityServerContext` fails cleanly with an error directing the caller to Network.framework, which owns TLS for duetto's macOS server backend. LWPT does not add deprecated, TLS-1.2-capped SecureTransport server mode or a macOS OpenSSL prerequisite.

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

The `Unix`-and-not-`Darwin` branch of `TransportSecurity.pas` loads the system shared object at runtime via `DynLibs.LoadLibrary` against standard names (`libssl.so.3` / `libcrypto.so.3` and a small set of fallbacks). The same loaded interface serves outbound clients and server accepts. Users need their distro's libssl package:

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

For an urgent CVE in a vendored unit or in a system TLS backend on Linux:

1. Patch on `main` with the fix + a `*.Test.pas` proving the fix.
2. Tag the patch version (`0.1.1`) — go straight from `0.1.0` to `0.1.1`, no pre-release.
3. The release notes name the CVE explicitly so downstream users can audit.

Client TLS on Windows (SChannel) and macOS (SecureTransport) is updated by the OS vendor. Linux OpenSSL and Windows server-accept OpenSSL CVE responses belong to the runtime provider; LWPT loads those libraries but does not ship them.

## Self-hosted runners (Tier 3 path)

Tier 1 / Tier 2 use GitHub-hosted runners (free for public repos; the platforms above are all supported on hosted runners as of 2025). Promoting a Tier 3 platform (FreeBSD, NetBSD, Linux ARM32) to Tier 1 requires a self-hosted runner — practical but a permanent operational cost. Not in scope for v1.
