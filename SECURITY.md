# Security policy

LWPT touches HTTPS over OpenSSL / SChannel / SecureTransport, fetches code from public git hosts, and invokes `fpc` over user-supplied source. Vulnerabilities are realistic — please report them through the channel below so we can patch + disclose responsibly.

## Reporting a vulnerability

**Use GitHub Security Advisories.** Open a private security advisory at:

<https://github.com/frostney/lwpt/security/advisories/new>

Please **do not** file public GitHub issues or pull requests for suspected vulnerabilities — that publishes the report to everyone before a fix is available.

A good report includes:

- LWPT version (`./build/lwpt --version`)
- Host platform (`uname -a` on Unix, `systeminfo` on Windows; `fpc -iV`)
- The manifest snippet, source tarball, or exact command that triggers the issue
- A minimal reproduction recipe if possible — even a vague description is fine if reproduction is hard
- Your assessment of the impact (binary corruption, code execution, sandbox escape, info disclosure, denial-of-service, etc.)

We'll acknowledge the report within **7 days** and aim for a fix-or-decline decision within **30 days**. Disclosure timeline target is **90 days from acknowledgement** (or earlier if a fix lands sooner) — the standard responsible-disclosure window.

## Supported versions

| Version line | Supported |
|--------------|-----------|
| Latest minor of the current major (`0.x.y`) | Yes — security fixes go here |
| Older minors (none yet — LWPT is pre-1.0) | No |
| Pre-release tags (`0.x.y-rc.*`) | No — use the matching stable for production |

Once LWPT reaches `1.0`, the policy will extend to the previous major line for a documented overlap window.

## In scope

Issues that meaningfully affect a consumer running `lwpt install` / `lwpt build` / `lwpt test`:

- Binary-content corruption (the original `HTTPClient` `Copy(PAnsiChar)` truncation that the byte-safe `AppendRawBytes` accumulator now fixes is the canonical example).
- Lockfile bypass — `lwpt install --frozen` failing to detect a tampered archive or extracted tree.
- Path traversal via crafted tarballs (the ustar / GNU long-name extractor) writing outside `.lwpt/modules/<dep>/`.
- Cross-process install lock failures that let two concurrent installs corrupt `.lwpt/`.
- Workspace symlink/junction creation pointing outside the repo root.
- Supply-chain hook execution — a dependency manifest's hooks should be silently dropped per [ADR-0011](./docs/adr/0011-build-lifecycle-hooks.md); a regression that runs them is a security issue.
- TLS-backend errors that disable certificate verification on any platform.

## Out of scope

Known limitations documented elsewhere:

- The Windows install lock (`LockFileEx`) ships alongside the Windows CI work; until it lands, concurrent installs on Windows can race. See [`docs/tooling.md`](./docs/tooling.md#environment-variables).
- LWPT is pre-1.0; the API surface (manifest format, lockfile schema, subcommand set) is not yet stable. Migrations are deliberate, not security issues.
- Issues affecting test-only paths (`*.Test.pas`, `tests/support/Tests.HTTPMockServer.pas`) — they don't ship in the release binary.

If you're unsure whether something qualifies, open the advisory anyway. We'd rather triage a non-issue than miss a real one.
