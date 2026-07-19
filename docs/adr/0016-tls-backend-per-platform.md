# TLS-backend per platform — SChannel on Windows, SecureTransport on macOS, OpenSSL on Linux/Unix

> **Amended by [ADR-0024](./0024-openssl-server-tls-accept.md).** This ADR now
> governs the outbound blocking client path only. Its historical statements
> that Windows must never load OpenSSL and that a raw DLL-name string scan is
> the correct guard are superseded for server accept: Windows servers
> runtime-load OpenSSL, while CI rejects both normal and delay imports.

The vendored `TransportSecurity` unit ([`packages/httpclient/source/TransportSecurity.pas`](../../packages/httpclient/source/TransportSecurity.pas)) carries one cross-platform abstraction over three OS-native TLS implementations: **SChannel** on Windows, **SecureTransport** on macOS (Darwin), and **OpenSSL** (loaded at runtime via `DynLibs`) on every other Unix. earlier the LWPT docs claimed the opposite: that the Windows release archive had to bundle `libssl-3-x64.dll` + `libcrypto-3-x64.dll` next to `lwpt.exe`, and that macOS expected Homebrew `openssl@3` — both **factually wrong**, contradicted by the actual `{$IFDEF}` switches in the vendored unit, the GocciaScript upstream that LWPT vendors verbatim, and the release.yml workflow itself (which never bundled DLLs in any release). This ADR reconciles the docs with reality and adds a CI guard mirroring [GocciaScript's same check](https://github.com/frostney/GocciaScript/blob/main/.github/workflows/ci.yml) so a future "add `uses OpenSSL` to a Windows codepath" mistake fails at build time instead of corrupting a release. Net effect: no code change (already correct), no release-artefact change (already correct), no consumer-side change (Windows users were never given DLLs to install in the first place). The fix is documentation + CI guard. The previously-documented "OpenSSL on Windows is bundled" Hard Constraint in [`AGENTS.md`](../../AGENTS.md) is retired and replaced with the correct platform-tier statement; [`docs/deployment.md`](../deployment.md), [`docs/quick-start.md`](../quick-start.md), [`docs/tooling.md`](../tooling.md), [`docs/architecture.md`](../architecture.md), and [`docs/README.md`](../README.md) get the matching rewrites.

## Considered Options

### What the actual TLS implementation looks like (no choice here — already chosen by vendoring)

`TransportSecurity.pas` selects the backend by FPC conditional:

| Platform | Backend | Source of the implementation |
|----------|---------|------------------------------|
| Windows (`{$IFDEF MSWINDOWS}`) | **SChannel** | Direct calls to `sspi.dll` / `secur32.dll` (Windows API; both ship with every Windows install since Windows 2000) |
| macOS / Darwin (`{$IFDEF DARWIN}`) | **SecureTransport** | Apple's framework; built into every macOS install |
| Other Unix (`{$IFDEF UNIX}` + `{$IFNDEF DARWIN}`) | **OpenSSL** | Loaded at runtime via `DynLibs.LoadLibrary` against the system shared object (`libssl.so.3` / `libcrypto.so.3` or platform equivalents) |

All three are wired into the same `StartTransportSecurity` / `TransportSecurityRead` / `TransportSecurityWrite` / `CloseTransportSecurity` API surface. `HTTPClient` consumes the unified API and never branches on platform itself. The vendoring is byte-identical to the GocciaScript upstream (`source/shared/TransportSecurity.pas`) as of the the verification (`diff -q` returns clean).

### Why the documentation drifted

The earlier spike had a working hypothesis that LWPT would link against OpenSSL on every platform — the simplest possible HTTPS story for a young Pascal toolkit. The vendoring of `TransportSecurity` from GocciaScript brought in the three-backend implementation, but the docs from the OpenSSL-everywhere era were never refreshed. The contradiction sat in plain sight for several waves because (a) macOS + Linux CI both worked fine (the docs claimed system OpenSSL on both, and the actual code happened to use system OpenSSL on Linux), and (b) no Windows release was ever cut, so the "bundle DLLs" instruction was never tested against reality. this caught it when the user asked the obvious "wait, GocciaScript doesn't bundle OpenSSL — why does LWPT?" question.

### Should we add the CI guard

- **Yes — mirror GocciaScript's check verbatim.** *Chosen.* A PowerShell read-bytes-as-Latin1 scan over the cross-built `lwpt.exe` for the substrings `libssl` / `libcrypto`. Catches every realistic way OpenSSL would creep back in: `uses OpenSSL` under a Windows-active branch (the unit hard-codes the DLL names as string literals for `LoadLibrary`), a vendored upstream change that flipped the Windows guard, a copy-paste from a Linux-only codepath. PowerShell because that's what the Windows test runner has natively; bash with `grep -ao` on the macOS release-build runner does the same job for the release.yml side. Both runs together cover both pipelines (`ci.yml` on push to main + `release.yml` on tag push).
- **No guard, trust the vendored unit.** Rejected: vendored code drifts when an upstream resync lands, when a `[LWPT patch]` is added in the wrong `{$IFDEF}` arm, when a future contributor genuinely needs OpenSSL on Windows for a specific reason and doesn't realise the release impact. The guard is one extra step per platform-relevant pipeline and runs in ~50ms; the asymmetry of "test passes / release ships a broken binary" is the kind of footgun CI guards exist to remove.
- **Run the guard at link time via fpc flags.** Rejected: FPC has no native "deny use of unit X" flag, so the implementation would be a post-link script anyway — same shape as what's chosen, less portable.

### Where the guard runs

- **In `ci.yml`'s test job under `if: runner.os == 'Windows'`.** *Chosen.* Test job already downloads the cross-built Windows binary; one extra PowerShell step is structurally cheap. Mirrors GocciaScript's same placement.
- **In `release.yml`'s build job under `if: matrix.os == 'win64' || matrix.os == 'win32'`.** *Also chosen.* Release.yml runs only on tag push and does not depend on a prior ci.yml run on the same commit; a release that introduces the regression at tag-cut time would slip past ci.yml's gate entirely. The release.yml guard runs on the macOS build runner using `LC_ALL=C grep -ao`, which is cheaper than spinning up Windows just for a strings check.
- **In `toolchain.yml`.** Rejected: the toolchain only knows how to *build* binaries; the binaries themselves don't exist at toolchain-build time.

### Macros / configurability

- **No build-time switch to force OpenSSL on Windows.** *Chosen.* If a future "I genuinely need OpenSSL on Windows" use case appears, it earns its own ADR — and a CI-guard exception with an explicit reason. The default and the CI guard align: SChannel-only.
- **`-dUSE_OPENSSL` to opt out of SChannel.** Rejected: would invite per-build-flavor divergence (release vs dev, CI vs local). The vendored unit's per-platform `{$IFDEF}` is already the single source of truth.

### What changes in the consumer-facing story

earlier the Windows install instructions told users to either (a) install OpenSSL DLLs themselves or (b) wait for the release archive to ship them. Both were false expectations. Post-amendment:

- **Windows users** download `lwpt-<version>-windows-x64.zip`, extract, run. No prerequisites beyond Windows itself (SChannel ships with the OS).
- **macOS users** download the `.tar.gz`, extract, run. No prerequisites (SecureTransport ships with the OS).
- **Linux users** need the distro's libssl package (`apt install libssl3`, `dnf install openssl-libs`, `apk add openssl3-libs`, etc.). The `TransportSecurity` unit's runtime-load attempts to find the .so by standard names + standard search paths; install instructions remain the same as earlier (this branch was always correct).

The `install.sh` + `install.ps1` scripts at `scripts/install.{sh,ps1}` do not need to be touched — neither references OpenSSL.

### Migration story

There is no migration. Windows users were never given a working OpenSSL bundle (release.yml never produced one); they could not have set up the docs-described flow. The docs change is the migration.

## Consequences

- **One less Hard Constraint.** `AGENTS.md`'s "OpenSSL on Windows is bundled. Releases ship `libssl-3-x64.dll` + `libcrypto-3-x64.dll`" line retires. Replacement: a single Hard Constraint on the per-platform TLS backend — SChannel + SecureTransport + OpenSSL, no platform-mixing.
- **`docs/deployment.md`'s Windows section** loses the "OpenSSL bundling" subheader entirely; the macOS section similarly loses the Homebrew-openssl line. Linux section is unchanged.
- **`docs/quick-start.md`** drops the "Windows needs OpenSSL DLLs" prerequisite row and the matching "Could not load libssl-3-x64.dll" common-error entry.
- **`docs/tooling.md`** drops the Windows + macOS bullets in the OpenSSL section; keeps the Linux one.
- **`docs/architecture.md`** drops the release-artefact "Windows ships with bundled OpenSSL DLLs" line.
- **`docs/README.md`** updates the one-line description of `deployment.md` to remove the OpenSSL phrasing.
- **CI guards in two pipelines.** `ci.yml`'s test job runs the PowerShell version on Windows runners; `release.yml`'s build job runs the bash version on the macOS cross-build runner for each Windows target. The guards are independent (different shells, different binaries — cross-built vs staged) and both must pass.
- **Smaller release archive.** earlier the docs promised ~5 MB of OpenSSL DLLs per Windows release; the archive never carried them, so this is a documentation correction, not a real size change. Real net change to Windows archives: zero.
- **Faster Windows startup.** SChannel is in-process (uses Windows' Security Service Provider Interface); OpenSSL would have been a runtime DLL load + InitSSLInterface roundtrip on first HTTPS call. No measurable user-visible difference at lwpt's call volumes, but the conceptual win is real.
- **Vendored-unit Hard Constraint stays.** [`AGENTS.md`'s "Vendored units stay verbatim" rule](../../AGENTS.md) means the `{$IFDEF MSWINDOWS}` SChannel branch + the `{$IFDEF UNIX}{$IFNDEF DARWIN}` OpenSSL branch + the `{$IFDEF DARWIN}` SecureTransport branch are not LWPT-editable. Any future LWPT-side patch in `TransportSecurity.pas` carries the usual `[LWPT patch]` marker and an entry in [`docs/vendored.md`](../packages.md); the cross-platform structure itself is upstream-owned. *(Note: ADR-0017 — written after this ADR — retired the "vendored" framing + the patch markers + the AGENTS.md "stay verbatim" Hard Constraint. The TLS-backend per-platform decision in this ADR's body stands; the surrounding policy text is historical.)*
- **Upstream-coordination note in `docs/vendored.md`.** No new patch marker — `TransportSecurity.pas` is byte-identical to GocciaScript upstream. The CI guard's existence is the LWPT-side enforcement that we don't accidentally diverge.
- **A future "support OpenSSL on Windows" request** earns its own ADR + CI-guard exception. The default is locked in.
