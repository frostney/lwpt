# Testing

How LWPT tests itself: the four-tier policy, the mock HTTP server, the binary-fetch regression that catches the byte-truncation bug, the fixture strategy, and the initial test backlog.

## Executive Summary

- **Four tiers** with explicit policy on when each runs: **Unit** (always), **Integration** (always), **E2E** (opt-in `--tier=e2e`; runs in CI's online job), **Manual** (never automatic).
- **E2E spawns `./build/lwpt` as a subprocess.** It does not `uses LWPT.Core` or call internal Pascal code. Catches CLI parsing, error format, exit codes, and the full pipeline that a real user sees.
- **The single most important test** is the HTTPClient binary-fetch regression in `packages/httpclient/source/HTTPClient.Test.pas`. It uses the mock HTTP server (`packages/httpclient/source/Tests.HTTPMockServer.pas`) to inject `#0` bytes into response headers and chunked bodies, deterministically pinning HTTPClient's byte-safe `AppendRawBytes` contract against regression.
- **TestingPascalLibrary is the framework.** Lives in the `testing` workspace package per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) (an earlier embedded-blob model extruded via `lwpt export testing` is retired). Each `*.Test.pas` is a self-contained program; `lwpt test` discovers, compiles, runs, and reads the exit code — no output parsing.
- **Fixtures are committed for small inputs (<100 KB).** Large artefacts are generated at test-run time from a deterministic seed so the repo stays small.
- **Status:** mock server, fixtures, and the initial backlog (~10 files) are in place. The framework canary (tier-0 — "the testing framework itself works") lives in `packages/testing/source/TestingPascalLibrary.Test.pas`.

## The four tiers

| Tier | Hits network? | Where | Runs in CI on every PR? | Runs in pre-commit hook? |
| --- | --- | --- | --- | --- |
| **Unit** | Never | Co-located in `source/` (`Foo.pas` ↔ `Foo.Test.pas`) | Yes | Yes (via `lwpt test`) |
| **Integration** | Never (mock server + local fixtures) | `tests/integration/` | Yes | Yes |
| **E2E** | Yes (live GitHub / GitLab / Bitbucket) | `tests/e2e/` | Yes (separate online job; retry-tolerant) | No |
| **Manual / spike** | N/A | Anywhere maintainer wants | No | No |

`./build/lwpt test` runs Unit + Integration by default. `./build/lwpt test --tier=e2e` includes the live tier.

## Test programs

Each `*.Test.pas` is a self-contained program:

```pascal
program MyUnit.Test;
{$mode delphi}{$H+}
uses
  TestingPascalLibrary,
  MyUnit;

type
  TMyUnitTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestAdds;
  end;

procedure TMyUnitTests.TestAdds;
begin
  Expect<Integer>(MyAdd(2, 2)).ToBe(4);
end;

procedure TMyUnitTests.SetupTests;
begin
  Test('addition works', TestAdds);
end;

begin
  TestRunnerProgram.AddSuite(TMyUnitTests.Create('MyUnit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
```

`lwpt test`:

1. Discovers every `*.Test.pas` under the manifest's `Units` dirs (plus `.` for the project root) — skipping `.lwpt/`, `build/`, `.git/`.
2. Compiles each via `fpc -Sh -Fu<units> -Fu.lwpt/modules <file> -o<bin>`.
3. Runs each binary; reads the exit code (0 = pass; non-zero = fail).
4. Aggregates: prints per-file pass/fail; exits 1 if any failed or any failed to compile.

Each `*.Test.pas` file sets its own compiler mode via its include directives. `lwpt test` does **not** force `-M<mode>` — every test file in this codebase ends up in delphi mode (either via an explicit `{$mode delphi}{$H+}` header or via `{$I Shared.inc}`), and forcing a mode would conflict with future workspace-package test files that ship their own directives.

## E2E tests spawn the binary

Per the grill (Q7 + Q11 correction), E2E tests do **not** `uses LWPT.Core`. They spawn `./build/lwpt` as a subprocess and validate via:

- Exit code.
- Parsed stdout / stderr.
- Side-effects on disk (`.lwpt/modules/` contents, lockfile shape, cfg contents, generated binaries).

A typical E2E test:

```pascal
program install_local_diamond.E2E.Test;
{$mode delphi}{$H+}
uses TestingPascalLibrary, SysUtils, Process;

procedure TestInstall;
var
  P: TProcess;
  ExitStatus: Integer;
begin
  SetCurrentDir('tests/e2e/fixtures/diamond/root');
  P := TProcess.Create(nil);
  try
    P.Executable := ExpandFileName('../../../../../build/lwpt');
    P.Parameters.Add('install');
    P.Options := [poWaitOnExit];
    P.Execute;
    ExitStatus := P.ExitStatus;
  finally
    P.Free;
  end;
  Expect<Integer>(ExitStatus).ToBe(0);
  ExpectTrue(FileExists('lwpt.lock'), 'install must write lwpt.lock');
  ExpectTrue(DirectoryExists('.lwpt/modules/leaf-a'),
             'install must extract leaf-a');
end;
```

This catches everything a unit test can't: CLI parsing, error formatting, exit-code contracts, the cross-platform `TProcess` story, OpenSSL availability, real path handling.

## The binary-fetch regression (the headline test)

The handoff calls out one specific test as the production-readiness gate: the `HTTPClient` byte-fetch regression that pins the byte-safe `AppendRawBytes` accumulator's contract. The original bug it caught was `Copy(PAnsiChar(...))` truncating response bytes at the first `#0` — corrupting binary downloads and poisoning subsequent header / body parsing.

The test must:

- **Deterministically** put `#0` bytes into both response headers and chunked bodies.
- **Force multi-chunk recv splits** so the header-accumulation path's byte handling is exercised at chunk boundaries.
- **Assert the response body's sha256** matches the expected value baked into the test.
- **Fail loudly** if the body is shorter than expected (the truncation symptom).

**Implementation: two complementary paths.**

| Path | Tier | What it catches |
| --- | --- | --- |
| **Mock HTTP server** (`tests/support/Tests.HTTPMockServer.pas` binds an ephemeral local port and serves crafted responses with `#0` traps) | Integration | The exact byte-truncation bug, deterministically, on every PR |
| **Pinned real artefact** (fetch a specific tagged release of a small known repo; assert sha256) | E2E | The full network stack end-to-end, including OpenSSL link-time behavior |

Both. The mock server is the regression net; the real artefact is the smoke test.

## Fixture strategy

| Fixture type | Path | Committed? |
| --- | --- | --- |
| Manifest TOML samples | `tests/fixtures/manifests/` | Yes |
| Lockfile samples | `tests/fixtures/lockfiles/` | Yes |
| Diamond-dep local source trees | `tests/fixtures/diamond/{root,a,b,c}/` | Yes |
| Crafted tar archives (incl. >100-byte prefix-split paths, GNU long names, symlinks) | `tests/fixtures/archives/` | Yes |
| Crafted HTTP response bodies (with `#0` traps) | `tests/fixtures/http/` | Yes |
| Large test artefacts (>100 KB) | `tests/fixtures/archives/large/` | **No** — generated at test-run time from a deterministic seed |

The rule: anything ≤ 100 KB is committed; anything larger is seeded. Repo size matters; cleverness in commit messages doesn't.

## Mock HTTP server

`tests/support/Tests.HTTPMockServer.pas` is a `TThread` subclass holding a `TInetServer` socket. Each test acquires its own ephemeral port via `bind(127.0.0.1, 0)`, serves a single configured response template, and dies. Approximately 150-200 LoC; reusable for any future HTTP-layer testing (redirects, content-length lies, chunked edge cases, partial-content responses).

The mock server is **necessary** for the byte-truncation regression — only by controlling the response bytes can you embed `#0` in specific positions. Pinned real artefacts can't deterministically reproduce the pathological case.

## Test backlog (all landed)

The original 10-file backlog from the handoff is in place: tier-0 + the headline HTTPClient byte-fetch regression, the manifest + resolver + extractor tests, the failure-mode + hardening tests, and the full E2E tier (CLI subprocess, mock-server fetch-failure, live GitHub/GitLab/Bitbucket, GNU long-name extractor).

### Landed

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`packages/httpclient/source/HTTPClient.Test.pas`** (the headline) | 5 tests in 1 suite | Byte-safe `AppendRawBytes` regression. Uses `packages/httpclient/source/Tests.HTTPMockServer.pas` to serve crafted responses with embedded `#0` bytes in body, body-prefix (header-recv path), and chunked frames; asserts the received bytes round-trip byte-perfectly via hex comparison. Includes a 32 KB response that forces multi-recv and exercises the path where header-accumulation has already buffered some body bytes. |
| **`source/LWPT.Core.Test.pas`** | 91 tests in 11 suites | **SHA-256 NIST vectors** (empty, "abc", 56-byte block-boundary pad, 1,000,000 "a" multi-block). **LoadManifest happy path / validation / extensions** (bare-string shorthand rejected, http source rejected, `[lwpt]`/`[format]`/`[generated]` parsing). **LoadLockfile** (missing / corrupt-TOML / no-schema / v1-migration-hint / empty-table / round-trip-fields). **VerifyAgainstLockfile** (matching graph + lock passes silently; tree-hash mismatch / archive-hash mismatch / orphan manifest dep / stale lockfile entry each raise `EVerifyError` naming the dep + the side that mismatched; local-source with empty archive-hash on both sides is the legitimate happy path and must not false-mismatch). Also covers source/version parsing, git ref parsing, include/exclude pruning, path globs, and custom source prefixes. |
| **`source/LWPT.Formatter.Test.pas`** | 15 tests in 3 suites | Running `lwpt format` twice on the same file is a no-op (the contract `--check` rests on). Plus the four canonical shapes that previously broke the parameter-rename propagation: nested record type only, nested procedure only, nested function only, both-at-once. Scope-expansion tests pin manifest include/exclude glob behavior for formatter discovery. |
| **`packages/semver/source/Semver.Test.pas`** | 12 tests in 3 suites | `Satisfies` happy path (caret/tilde/exact + prerelease exclusion); `RangeIntersects` matrix the resolver leans on (caret+caret across major boundaries, exact+caret, union ranges); `MaxSatisfying` correctness (highest in range, empty when none match, ignore out-of-range). |
| **`packages/testing/source/TestingPascalLibrary.Test.pas`** | 1 test | The framework canary, lives with the package per ADR-0015. Uses TPL at arm's length (one `Expect<Boolean>(True).ToBe(True)`) so that if TPL itself breaks, this file's failure narrows the blame instead of the suite reporting opaquely. Custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode. |
| **`tests/integration/InstallLocalDiamond.Test.pas`** | 9 tests in 2 suites | **Full transitive-resolver run** over the canonical diamond graph (root → branch-a + branch-b → leaf-c) with path-syntax local sources (`"../a"`, `"../b"`, `"../c"`) so no network. Asserts lockfile + cfg + tree shape + idempotence + `--frozen` happy path, plus manifest-path invocation from a different cwd. **Tamper detection** — edits a file under `.lwpt/modules/leaf-c/`, runs `--frozen`, asserts `EVerifyError` naming the tree-hash mismatch + the dep; then re-runs install (non-frozen) and confirms `--frozen` succeeds again (the documented recovery). |
| **`tests/integration/ExtractPathological.Test.pas`** | 8 tests in 2 suites | **Pathological ustar shapes** — baseline short path, > 100-char prefix-split, symlink deferred-link pass. **GNU 'L' long-name** — paths > 255 bytes (past ustar's prefix-split ceiling) wrapped in a GNU `'L'` typeflag header + body carrying the real name; the extractor's pending-long-name buffer carries the name across the header boundary. **Failure modes** — missing archive raises `EExtractError`, truncated gzip leaves Dest empty, invalid gzip magic same contract, tar truncated mid-entry never produces a byte-equal file. |
| **`tests/integration/CLIOptions.Test.pas`** | 6 tests in 1 suite | Spawns `./build/lwpt` with various argv. `--help` + `-h` list every subcommand; unknown verb exits non-zero. Option-parsing regression: `build --mode release` (space-separated value) and `build --mode=release` (equals-separated value) must both parse to "release" and produce the same outcome. Invalid `--mode` value exits non-zero. Scratch project (tiny lwpt.toml + one trivial source) built in-test under `build/tests/tmp/cli-options-e2e/`. |
| **`tests/integration/InstallFetchFailure.Test.pas`** | 3 tests in 1 suite | Spawns `lwpt install` against a manifest with a local-path source pointing at a non-existent directory. Exit non-zero, error message names both the dep AND the missing path, and `.lwpt/tmp/` is empty after the failure (no orphans). HTTP-failure variants (HTTP 500 / unreachable port / timeout) require a URL-redirect env-var hook and ship in v1.x. |
| **`tests/integration/Init.Test.pas`** | 10 tests in 1 suite | Spawns `lwpt init --yes` + interactive in scratch dirs. Asserts manifest + hello-world `.pas` + `.gitignore` artefacts, sanitised `program <ident>;` declaration for hyphenated names, that `--yes` does not create a lockfile (install owns it), that `lwpt build` after `init --yes && lwpt install` produces a runnable binary at `<BuildDir>/<EntryName>`, refuse-to-clobber + `--force` semantics, and `.gitignore` idempotence on re-init. |
| **`tests/integration/Hooks.Test.pas`** | 5 tests in 1 suite | Spawns build/test flows against scratch manifests with lifecycle hooks. Covers prebuild/postbuild/pretest execution, staleness-gated skip behavior, and dep-manifest hook dropping. |
| **`tests/integration/Repair.Test.pas`** | 3 tests in 1 suite | Spawns `lwpt repair` in scratch projects. Covers clean no-op behavior, stale install-lock removal, and `.lwpt/tmp/` cleanup without touching committed module/archive state. |
| **`tests/integration/Run.Test.pas`** | 6 tests in 1 suite | Spawns `lwpt run` against scratch projects. Covers user-script execution and exit-code propagation, built-in aliasing with flag passthrough, unknown-script errors, list mode omitting retired `export`, and `export` as an allowed user script name. |
| **`tests/integration/Version.Test.pas`** | 4 tests in 1 suite | Spawns version-reporting forms and verifies output shape plus drift protection against `lwpt.toml`'s `[package].version`. |

### E2E tier

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`tests/e2e/InstallGitHub.E2E.Test.pas`** | 6 tests in 1 suite | Live GitHub fetch of `octocat/Hello-World @ 7fd1a60b…` — the most stable public git ref in existence. Install exits zero, modules tree extracts under `.lwpt/modules/`, archive caches under `.lwpt/archives/<dep>-<ref>.tar.gz`, lockfile records both `archiveHash` and `computedHash`, `--frozen` re-verifies without network, **and** `--frozen` detects an archive byte-tamper (the archive-mismatch path the local-only diamond fixture cannot reach). Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallGitLab.E2E.Test.pas`** | 4 tests in 1 suite | Live GitLab fetch of `gitlab-org/release-cli @ v0.16.0`. Validates the GitLab archive-URL pattern in `FetchURL`. Same shape as the GitHub suite: install exit / modules dir / lockfile contents / frozen reverify. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallBitbucket.E2E.Test.pas`** | 4 tests in 1 suite | Live Bitbucket fetch of `atlassian/atlaskit @ d7ac1acad54e…`. Validates the Bitbucket archive-URL pattern. Bitbucket strips the top-level dir hash-suffixed; `StripFirstComponent` handles it. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallDirectArchivesWindows.E2E.Test.pas`** | 3 tests in 1 suite | Windows-only live fetch of direct GitHub codeload + GitLab archive URLs through `lwpt install`. Bypasses source-kind URL construction so the suite specifically exercises the SChannel archive-body read path that previously corrupted `SECBUFFER_EXTRA` leftovers. Honors `LWPT_SKIP_NETWORK=1` and self-skips on non-Windows hosts. |
| **`tests/e2e/InstallScript.E2E.Test.pas`** | 3 tests in 1 suite | Unix-only. Runs `scripts/install.sh` end-to-end against the current **latest** published release — no pinned version constant. The test resolves "latest" the same way `install.sh` does (GET `/releases/latest`, which returns the newest non-prerelease-flagged release), passes that tag explicitly to the script, and **derives** the expected `--version` from it (binary == tag, per [ADR-0018](./adr/0018-release-version-stamp-from-tag.md)). The script curls the asset, verifies the checksum, extracts, installs; the test asserts the install exits zero, the binary lands in `INSTALL_DIR` + is executable, and reports the resolved tag. This is the suite that would have caught the macOS `.zip` regression (asset-name mismatch → 404 against a release we know exists → fail). Honors `LWPT_SKIP_NETWORK=1`; self-skips on non-Unix, on clean connect/DNS failure (transient downtime), and until the first non-prerelease release exists (prerelease-flagged `rc.x` are covered by `release.yml`'s per-release install-smoke job instead). |

### Supporting infrastructure

- **`tests/support/Tests.HTTPMockServer.pas`** — Unix-only `TThread`-backed single-shot HTTP server. Binds an ephemeral port via `fpSocket`/`fpBind`/`fpListen`/`fpAccept`, serves caller-supplied raw response bytes (no auto-Content-Length, no implicit headers — so pathological shapes are constructible), dies after one request. Two builder helpers: `BuildSimpleResponse(body)` and `BuildChunkedResponse(chunks)`. The Windows path lands when CI hits Windows.
- **`tests/support/Tests.TarSynth.pas`** — minimal POSIX ustar tarball synthesiser. Builders for regular file entries (with automatic prefix-split for > 100-byte paths), symlink entries, directory entries, **and** GNU `'L'` long-name entries via `MakeGnuLongNameRegularFileEntry`. POSIX checksum computed correctly (the eight-spaces convention). `Gzip(plain)` wraps in a gzip stream. Deliberately scoped — no PaxHeader, GNU `'K'` long-linkname not synthesised (extractor handles both via the same pending-long-name buffer), no sparse files.
- **`tests/support/Tests.LwptSubprocess.pas`** — `TProcess` wrapper for the E2E tier. Spawns `./build/lwpt` with given argv, captures stdout + stderr separately (no merge), supports per-test CWD + env-var overrides, honors `LWPT_SKIP_NETWORK=1` (`SkipNetworkTests` helper). The drain loop reads incrementally while the child runs to avoid pipe-buffer deadlock on long outputs. Also exposes `IsNetworkUnavailable(result)` — the narrow connect/DNS-failure detector the live-network suites use to **skip on transient third-party host downtime** (a `Failed to connect to` / `Failed to resolve host` from HTTPClient) while still failing hard on a content/hash/parse mismatch. See [`ci.md`](./ci.md#transient-host-downtime-skips-it-does-not-fail).
- **Testable internals exposure** — `SHA256Hex` remains in `LWPT.Core`; `LoadManifest` and manifest model types live in `LWPT.Manifest`; `LoadLockfile`, `VerifyAgainstLockfile`, and `ExtractArchive` live in `LWPT.Install`. Documented as testable-internal surface, not part of the consumer contract.
- **`--tier` flag** on `lwpt test` — default tier runs unit + integration; `--tier=e2e` adds the network-touching tier.
- **Test-artefact placement** — `lwpt test` compiles each `*.Test.pas` into `build/tests/<sanitised-path>/<name>` (gitignored via `build/`) and dumps FPC intermediates there too via `-FE`. No more `.o`/`.ppu`/binary pollution under `source/`.
- **`tests/support/` auto-discovery** — `LWPT.Command.Testing.CmdTest` adds `tests/support` to the FPC `-Fu`/`-Fi` paths automatically when it exists. `LWPT.Command.Format.CmdFormat` walks `tests/` in addition to `Man.Units` so project-owned test helpers are held to the same formatter rules as `source/`.

### Counts

| Tier | Files | Test cases |
| --- | --- | --- |
| Unit (`source/*.Test.pas` + package self-tests) | 5 | 124 |
| Integration (`tests/integration/*.Test.pas`) | 9 | 54 |
| E2E (`tests/e2e/*.E2E.Test.pas`) | 5 | 20 |
| **Total** | **19** | **198** |

### Deferred to v1.x

| Item | Reason | When |
| --- | --- | --- |
| **HTTP-failure tests with URL injection** (HTTP 500 / unreachable port / timeout via mock server) | `FetchURL` builds URLs from a hardcoded base prefix per source kind; pointing it at a mock server requires an env-var hook (e.g. `LWPT_GITHUB_BASE_URL`). The fetch-failure contract (EFetchError raised, exit ≠ 0, tmp clean) is already covered via the local-source-missing path in `InstallFetchFailure.Test.pas`; URL-injection is the more thorough but lower-priority follow-up. | v1.x |
| **~~Lockfile records host~~** | **Solved.** The v3 lockfile's `source` field is the verbatim manifest string (`gitlab:org/repo`) and `resolvedURL` is the actual archive URL (`https://gitlab.com/...`). Host is recoverable from either. See ADR-0009. | done |
| **Windows install lock + mock server + subprocess paths** | Install locking is covered through `lwpt install` / `lwpt repair` behavior rather than direct lock-type tests. Tests.HTTPMockServer and Tests.LwptSubprocess still need Windows-native CI coverage for the substantive OS-specific paths. | in progress |
| **`source/CLI.Subcommands.Test.pas`** | `CLIOptions.Test.pas` covers the same surface from the binary side, which is the more realistic shape; pure-Pascal unit tests of the option parser remain redundant. | Not planned |

## TestingPascalLibrary self-test

LWPT (and every other LWPT-using project) consumes `TestingPascalLibrary` via the `testing` workspace package, then uses it to test everything else. If `TestingPascalLibrary` breaks, none of the project's `*.Test.pas` files can tell us so. Mitigation: the `packages/testing/source/TestingPascalLibrary.Test.pas` canary exercises the framework's basic assertions through a one-test suite with custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode — using TPL itself at arm's length. One file; catches the catastrophe.

**Status:** in place; lives in `packages/testing/` per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md).

## Snapshot tests

Out of scope. The formatter's idempotence test catches the same regressions snapshot tests would, with less ceremony.

## Mocking framework

Out of scope. Pascal mocking frameworks (Delphi-Mocks, etc.) are heavyweight and not needed when interface injection or `var`-swap patterns handle every case LWPT has.
