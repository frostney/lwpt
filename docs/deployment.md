# Deployment

Platform support tiers, the per-platform TLS backend story, the release process, the macOS quarantine workaround, and the codesigning policy for v1.

## Executive Summary

- **Six release targets** map to the matrix in [`docs/ci.md`](./ci.md): `aarch64-darwin` + `x86_64-darwin` + `x86_64-linux` + `aarch64-linux` + `x86_64-win64` + `i386-win32`. All six tested natively on every push to `main` (per `ci.yml`); all six published per release tag (per `release.yml`).
- **TLS backend is platform-native.** SChannel on Windows, SecureTransport on macOS, OpenSSL on Linux. Per [ADR-0016](./adr/0016-tls-backend-per-platform.md). Windows and macOS releases ship the binary alone — no OpenSSL DLLs. Linux relies on the distro's libssl package.
- **A CI guard** in both `ci.yml` (test job, Windows runners) and `release.yml` (build job, Windows targets) hard-fails if `lwpt.exe` references `libssl` / `libcrypto`, mirroring [GocciaScript's same guard](https://github.com/frostney/GocciaScript/blob/main/.github/workflows/ci.yml).
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

Per [ADR-0016](./adr/0016-tls-backend-per-platform.md), the vendored `TransportSecurity.pas` ([`packages/httpclient/source/TransportSecurity.pas`](../packages/httpclient/source/TransportSecurity.pas)) carries one cross-platform abstraction over three OS-native TLS backends:

| Platform | Backend | Where it comes from | User prerequisite |
|----------|---------|---------------------|-------------------|
| **Windows** | SChannel | `sspi.dll` / `secur32.dll` (Windows API; built into the OS since Windows 2000) | None — ships with Windows |
| **macOS** | SecureTransport | Apple's framework (built into every macOS install) | None — ships with macOS |
| **Linux + other Unix** | OpenSSL | System shared object via `DynLibs.LoadLibrary` at runtime | Distro's libssl package — see "Linux" below |

`HTTPClient` consumes the unified `StartTransportSecurity` / `TransportSecurityRead` / `TransportSecurityWrite` / `CloseTransportSecurity` API; the per-platform branching lives behind that surface. The unit is byte-identical to GocciaScript's older copy (last verified via `diff -q`), reflecting the co-developed history; per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT is now the canonical source and the SChannel + SecureTransport branches evolve here going forward.

### Windows: SChannel (no DLLs to bundle)

`lwpt.exe` calls into Windows' Security Service Provider Interface (SSPI) directly via the `Windows` unit + the SChannel constants in `TransportSecurity.pas`. There are no third-party DLLs to ship. The Windows release archive contains exactly:

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

Earlier docs claimed the archive bundled `libssl-3-x64.dll` + `libcrypto-3-x64.dll` — that was a documentation bug corrected by [ADR-0016](./adr/0016-tls-backend-per-platform.md). The release archive never bundled them and it should not — SChannel is the only TLS backend on Windows. The `release.yml` workflow does not stage any DLLs.

#### CI guard

To prevent a future regression (someone adds `uses OpenSSL` under a Windows-active codepath; the unit's source registers DLL names as string literals for `LoadLibrary`), both `ci.yml` and `release.yml` include a guard step that fails the build if the cross-built `lwpt.exe` contains `libssl` or `libcrypto` substrings:

- `ci.yml` test job: PowerShell read-bytes-as-Latin1 scan, gated on `runner.os == 'Windows'`. Mirrors GocciaScript's same guard step.
- `release.yml` build job: bash `grep -ao libssl\|libcrypto`, gated on Windows targets. Runs on the macOS cross-build runner against the staged binary.

The guards are independent (different shells, different binaries — cross-built artefact vs staged-for-release artefact); both must pass.

### macOS: SecureTransport (no Homebrew dependency)

The `Darwin` branch of `TransportSecurity.pas` calls into Apple's SecureTransport framework, which is built into every macOS install. No `brew install openssl@3`, no `DYLD_LIBRARY_PATH` shenanigans, no library version pinning. macOS release archives ship the binary alone, same shape as the Windows archives (without the `.exe` suffix).

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

The `Unix`-and-not-`Darwin` branch of `TransportSecurity.pas` loads the system shared object at runtime via `DynLibs.LoadLibrary` against standard names (`libssl.so.3` / `libcrypto.so.3` and a small set of fallbacks). Users need their distro's libssl package:

- Debian / Ubuntu: `apt install libssl3`
- Fedora / RHEL: `dnf install openssl-libs`
- Alpine: `apk add openssl3-libs`
- Arch: `pacman -S openssl`

The library is almost always already installed (most distros pull it in transitively via `curl`, `git`, `wget`, etc.). When packaging for a specific distro (`.deb`, `.rpm`), declare the libssl package as a runtime dependency. The release archive for Linux is a plain `.tar.gz` of the binary + docs; distro packages are a separate, non-v1 workstream.

If `lwpt install` fails with `HTTPS requires OpenSSL but it could not be loaded`, the distro's libssl package is missing or the binary's `dlopen` could not find it. Install the package; LWPT does not bundle a fallback.

## Release process

1. **Tag.** `git tag v0.1.0` on a green `main`. Pre-release tags use the `v0.1.0-rc.1` form (auto-detected by `release.yml` and published as `prerelease: true`).
2. **`release.yml` triggers.** Mirrors `ci.yml`'s cross-build matrix exactly (same flag set, same toolchain cache key), then packages each target as `tar.gz` (Unix) / `zip` (Windows) plus a SHA-256 checksums file.
3. **GitHub Release published.** Auto-generated release notes from `.github/release.yml`'s category config, attached: all six archives + the checksums file. Archive naming:

   ```text
   lwpt-<version>-macos-arm64.tar.gz
   lwpt-<version>-macos-x64.tar.gz
   lwpt-<version>-linux-x64.tar.gz
   lwpt-<version>-linux-arm64.tar.gz
   lwpt-<version>-windows-x64.zip
   lwpt-<version>-windows-x86.zip
   lwpt-<version>-checksums.txt
   ```

4. **Install scripts** at `scripts/install.sh` (Linux/macOS) + `scripts/install.ps1` (Windows) point at the GitHub Releases asset URLs; both download the per-platform archive + checksums file and verify SHA-256 before installing.

There are no hand-built release artefacts. If `ci.yml` is broken at tag time, fix it first (the `ci.yml` push-to-main run validates the same flag set + matrix that `release.yml` uses).

## Hotfix releases

For an urgent CVE in a vendored unit or in a system TLS backend on Linux:

1. Patch on `main` with the fix + a `*.Test.pas` proving the fix.
2. Tag the patch version (`v0.1.1`) — go straight from `v0.1.0` to `v0.1.1`, no pre-release.
3. The release notes name the CVE explicitly so downstream users can audit.

System TLS on Windows (SChannel) and macOS (SecureTransport) is updated by the OS vendor; LWPT does not ship those code paths. Linux OpenSSL CVE responses are entirely a distro-package matter — LWPT just consumes whatever `libssl` the system provides.

## Self-hosted runners (Tier 3 path)

Tier 1 / Tier 2 use GitHub-hosted runners (free for public repos; the platforms above are all supported on hosted runners as of 2025). Promoting a Tier 3 platform (FreeBSD, NetBSD, Linux ARM32) to Tier 1 requires a self-hosted runner — practical but a permanent operational cost. Not in scope for v1.
