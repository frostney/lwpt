# Testing

How LWPT tests itself: the four-tier policy, the mock HTTP server, the binary-fetch regression that catches the byte-truncation bug, the fixture strategy, and the current test inventory.

## Executive Summary

- **Four tiers** with explicit policy on when each runs: **Unit** (always), **Integration** (always), **E2E** (opt-in `--tier=e2e`; runs in CI's online job), **Manual** (never automatic).
- **E2E crosses a real process or operating-system boundary.** Root CLI tests spawn `./build/lwpt` without `uses LWPT.Core`; package E2E tests use only their package's published API against real operating-system resources.
- **The single most important test** is the HTTPClient binary-fetch regression in `packages/httpclient/source/HTTPClient.Test.pas`. It uses the mock HTTP server (`packages/httpclient/source/Tests.HTTPMockServer.pas`) to inject `#0` bytes into response headers and chunked bodies, deterministically pinning HTTPClient's byte-safe `AppendRawBytes` contract against regression.
- **TestingPascalLibrary is the framework.** Lives in the `testing` workspace package per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md) (an earlier embedded-blob model extruded via `lwpt export testing` is retired). Each `*.Test.pas` is a self-contained program; `lwpt test` discovers it, validates a compiler-neutral request, compiles through the selected project compiler profile, retains raw compiler output, stores normalized diagnostics, then runs a successful binary and reads its exit code.
- **Fixtures are committed for small inputs (<100 KB).** Large artefacts are generated at test-run time from a deterministic seed so the repo stays small.
- **Status:** the unit, integration, and E2E inventory is listed below; live `lwpt test` discovery is authoritative. The framework canary (tier-0 — "the testing framework itself works") lives in `packages/testing/source/TestingPascalLibrary.Test.pas`.

## The four tiers

| Tier | Hits network? | Where | Runs in CI on every PR? | Runs in pre-commit hook? |
| --- | --- | --- | --- | --- |
| **Unit** | Never | Co-located in `source/` (`Foo.pas` ↔ `Foo.Test.pas`) | Yes | No |
| **Integration** | Never (mock server + local fixtures) | `tests/integration/` | Yes | No |
| **E2E** | Sometimes (live hosts or loopback only) | `tests/e2e/` and package-owned `tests/e2e/` | Linux leg only (dedicated `pr.yml` step per #102); every platform post-merge via `ci.yml` | No |
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
2. Schedules independent programs concurrently through the machine-wide
   worker budget and the selected project compiler profile. The built-in
   `fpc` profile compiles each via
   `fpc -Sh -Fu<units> -Fu.lwpt/modules <file> -o<bin>` in its own
   session-private output directory.
3. Runs each successfully compiled binary under the same worker lease and
   reads the exit code (0 = pass; non-zero = fail).
4. Aggregates captured diagnostics in sorted source-path order; exits 1 if
   any failed or any failed to compile.

Concurrency is automatic by default and cannot exceed the shared
`LWPT_WORKER_BUDGET`. `--jobs=N` sets a smaller invocation ceiling;
`--jobs=1` provides a deterministic serial lane. Numeric bail counts both
compiler and runtime failures:

```toml
[test]
bail = 0 # default: run the complete queue
```

`--bail=N` overrides the manifest for one invocation. A positive threshold
stops new scheduling as soon as that many failures have been observed,
terminates and reaps active compiler/test children, and reports the remaining
programs as cancelled. `--bail=0` always runs the complete queue. CI should
use `--bail=1` for fast feedback.

Each `*.Test.pas` file sets its own compiler mode via its include directives. `lwpt test` does **not** force `-M<mode>` — every test file in this codebase ends up in delphi mode (either via an explicit `{$mode delphi}{$H+}` header or via `{$I Shared.inc}`), and forcing a mode would conflict with future workspace-package test files that ship their own directives.

## E2E tests cross a real boundary

Root CLI E2E tests do **not** `uses LWPT.Core`. They spawn `./build/lwpt` as a subprocess and validate via:

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

This catches everything a unit test cannot: CLI parsing, error formatting, exit-code contracts, the cross-platform `TProcess` story, OpenSSL availability, and real path handling. A package-owned E2E test follows the same arm's-length rule: it imports only the package's published units and crosses a real operating-system boundary. The HTTPClient TLS socket E2E therefore drives its public server API through a caller-owned nonblocking loopback socket instead of calling private helpers.

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
| **Mock HTTP server** (`packages/httpclient/source/Tests.HTTPMockServer.pas` binds an ephemeral local port and serves crafted responses with `#0` traps) | Integration | The exact byte-truncation bug, deterministically, on every PR |
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
| Pinned Lakon 0.1.0 help, version, and argument contracts | `tests/fixtures/compiler-drivers/lakon/0.1.0/` | Yes |
| Pinned Blaise v0.13.0 help and argument contracts | `tests/fixtures/compiler-drivers/blaise/v0.13.0/` | Yes |
| Large test artefacts (>100 KB) | `tests/fixtures/archives/large/` | **No** — generated at test-run time from a deterministic seed |

The rule: anything ≤ 100 KB is committed; anything larger is seeded. Repo size matters; cleverness in commit messages doesn't.

## Mock HTTP server

`packages/httpclient/source/Tests.HTTPMockServer.pas` exposes `TMockHTTPServer`, which owns an internal `TThread` over raw sockets. Each test acquires its own ephemeral port via `bind(127.0.0.1, 0)`, serves a single configured response template, and dies. Reusable for any future HTTP-layer testing (redirects, content-length lies, chunked edge cases, partial-content responses).

The mock server is **necessary** for the byte-truncation regression — only by controlling the response bytes can you embed `#0` in specific positions. Pinned real artefacts can't deterministically reproduce the pathological case.

### Pointing `lwpt install` at the mock server

`FetchURL` builds archive URLs from a hardcoded base prefix per source kind, so an install cannot be aimed at a local port without a seam. `LWPT_TEST_ARCHIVE_ORIGIN` is that seam, and it is deliberately the narrowest thing that works:

- It is read at the archive-fetch boundary **after** canonical URL construction. The manifest, the host templates, and the resolved path are all exercised exactly as in production; only the origin is swapped, and the canonical path is preserved.
- Unset or empty, the canonical URL is used byte for byte. That identity is asserted, not assumed.
- The normal accepted shape is a bare `http://<numeric IPv4 loopback>:<port>` origin. On Windows only, the non-routable limited-broadcast address is also accepted as a preflighted immediate-failure fallback. A remote host, a name needing DNS (including `localhost`), a missing port, a path, user information, and any non-`http` scheme are all refused with an error naming the variable. The seam therefore cannot express an arbitrary insecure download, which is why it can live in the shipped binary rather than behind a build flag.
- `LWPT_TEST_ARCHIVE_TIMEOUT_MS` bounds the loopback archive request and is honoured **only** while the origin override is active, so it cannot become a production knob on its own. It defaults to 5000 ms and accepts 1 to 600000. The override also sets HTTPClient's generic redirect budget to zero, so a fixture response cannot redirect the request to another origin; ordinary requests retain the default budget of 20 redirects.

`tests/integration/InstallFetchFailure.Test.pas` owns both halves: the pure accept/refuse table and the wire-level failure modes driven through the real `lwpt install` subprocess. Both run on Unix and native Windows through the same cross-platform mock server.

## Test inventory

The original backlog is landed and the inventory below tracks the current
test programs. Counts are taken from their registered `Test(...)` cases.

### Landed

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`packages/httpclient/source/HTTPClient.Test.pas`** (the headline) | 26 tests in 3 suites | Byte-safe `AppendRawBytes` regression, mock-server lifecycle, and response resource bounds, substantive on Unix and native Windows. Uses `packages/httpclient/source/Tests.HTTPMockServer.pas` to serve crafted fixed-length, chunked, close-delimited, idle, and slow-drip responses. Pins byte-perfect embedded-`#0` handling; one-byte segmented writes; bounded teardown before accept and during a silent accepted connection; deterministic socket/thread/WinSock accounting across repeated success, failure, and unstarted cycles; exact-limit and over-limit body/header behavior; strict and duplicate `Content-Length` handling; malformed chunk sizes; fixed-length truncation; a caller-controlled redirect budget; and the monotonic whole-request deadline through both response reads and an idle TLS handshake. Includes a 32 KB response that forces multi-recv and exercises the path where header accumulation has already buffered body bytes. |
| **`packages/httpclient/source/TransportSecurity.Test.pas`** | 23 tests in 1 suite | Pins the PKCS#12 memory-BIO server seam: authenticated `Active` state; independently bounded encrypted-input and encrypted-output defaults, minimums, maximums, and invalid configurations; accepted-prefix admission, high/low watermark hysteresis, cumulative accepted/consumed input counters, and exact pending/remaining output state; stable retained-output pointers; internal plaintext retention across `SSL_write` WANT; server-API bounds clamping; empty, UTF-8, embedded-NUL, oversize, garbage, wrong-pass, missing-path, and leaf-plus-intermediate identities; reusable handshakes; plaintext and partial-ciphertext round trips; stale error queues; `SSL_ERROR_SYSCALL`, `SSL_ERROR_ZERO_RETURN`, fatal-handshake, and fatal-shutdown poisoning; graceful `close_notify`; the TLS 1.2 floor; and refused renegotiation. Windows and Unix-not-Darwin run the 22 OpenSSL cases and skip the Darwin stub; Darwin runs the actionable Network.framework stub and records 22 platform skips. The functional OpenSSL cases are pure in-memory and offline. |
| **`packages/cli/source/CLI.Parser.Test.pas`** | 9 tests in 1 suite | Self-spawns in child mode so `ParseCommandLine` consumes real argv. Covers separated valued short options (including hyphen-leading values), opt-in attached values, repeatable `-Fu` / `-d` values, exact-before-longest-prefix matching for multi-character names, missing and unknown short-option errors, unchanged valueless flags, and both existing long-value forms. |
| **`packages/cli/source/CLI.Subcommands.Test.pas`** | 6 tests in 1 suite | In-process coverage of the subcommand registry: `Count`/`Item` iterate in registration order, `Find` resolves case-insensitively to the same object, each subcommand exposes its option objects, out-of-range `Item` access raises, and the optional completion callback receives the resolved command name, exit code, and elapsed milliseconds exactly once without being able to replace a nonzero dispatch result — the registry-side complement to the binary-side `CLIOptions.Test.pas`. |
| **`source/LWPT.BuildRequest.Test.pas`** | 12 tests in 1 suite | Pins canonical versioned TOML serialization and parse round-trips for build, probe, result, and capability documents; unsupported-schema failures; ordered extra arguments; compiler-independent target tuples; Windows target-name recognition; explicit incompatibility reasons; and normalized result validation. |
| **`source/LWPT.CompilerDriver.External.Test.pas`** | 8 tests in 1 suite | Runs a real short-lived proxy for probe and compile, proving canonical TOML stdin/stdout, live refresh, bounded raw stderr context, result/exit agreement, primary and extra-artifact confinement, explicit `--clean` rejection, timeout cleanup when a sleeping child never reads its large stdin, bounded writer cancellation when an escaped descendant retains stdin, and retain/discard drainage plus tree termination after capture overflow. |
| **`source/LWPT.CompilerDriver.Delphi.Test.pas`** | 12 tests in 1 suite | Pins the built-in opt-in profile, five verified executable/target tuples, live per-operation identity/version/target probes, bounded failure context, the Delphi 12 version floor, executable/header and requested-target mismatch failures without fallback, neutral argument translation, managed-option rejection, normalized source diagnostics, and exact private artifact renaming without requiring a Delphi installation or license. |
| **`source/LWPT.CompilerRegistry.Test.pas`** | 14 tests in 1 suite | Covers build-entry/project/embedding/built-in precedence, the FPC fallback, built-in Delphi, Blaise, and Lakon selection, explicit executable resolution, Lakon host-factory precedence and implicit-default replacement, script rejection, and case-insensitive per-invocation caching. Factory coverage pins wrong-identity rejection, independent version enforcement, rejected-object cleanup, exactly-once selection ownership, and refusal to shadow reserved built-in drivers. |
| **`source/LWPT.BuildSession.Test.pas`** | 22 tests in 1 suite | Covers unique private paths, bounded collision-resistant keys, atomic/stale publication, parsed-manifest binding, compiler-argument fingerprinting, implicit, declared, and postbuild-hook input hashing, filesystem-identity publication locks, symlinked workspace inputs, and owner-guarded repair. |
| **`source/LWPT.Command.Build.Test.pas`** | 3 tests in 1 suite | Covers compiler-process cancellation with output capture and child reaping, normal-exit descendant handling, and non-zero exit-code reporting. |
| **`source/LWPT.CompilerDriver.FPC.Test.pas`** | 19 tests in 1 suite | Covers capability-probe caching, target dispatch, timeout cleanup, request compatibility, build/test argument translation, ordered extra-argument forwarding and validation, nil-driver rejection, version failures, stale-artifact classification, structured diagnostics, and Windows executable-path normalization. |
| **`source/LWPT.CompilerDriver.Blaise.Test.pas`** | 15 tests in 1 suite | Pins the Blaise v0.13.0 identity/help and exact argument fixtures; proves per-operation live probing, the minimum release floor, verified Linux/FreeBSD x86-64 capability filtering, no target fallback, dev/release/clean translation, managed-argument and output-suppression protection, explicit unsupported-feature diagnostics, and normalized diagnostics/artifacts. |
| **`source/LWPT.CompilerDriver.Lakon.Test.pas`** | 17 tests in 1 suite | Pins the released Lakon 0.1.0 identity, help, target, and exact argument fixtures; proves two live probes per capability request, the minimum version, WASI-only capabilities, session-private no-cache translation including generated cfg unit paths with stable deduplication, explicit rejection of native test execution without a host runner, unsupported mode/input/argument failures, and normalized diagnostics/artifacts. The executable itself is replaced by deterministic fixtures in normal CI; compiling with a live Lakon checkout is optional and non-gating. |
| **`source/LWPT.Core.Test.pas`** | 131 tests in 20 suites | **SHA-256 NIST vectors** (empty, "abc", 56-byte block-boundary pad, 1,000,000 "a" multi-block). **HashTree paths** pin the exact nested-tree digest layout and require slash-separated relative paths on every platform. **LoadManifest happy path / validation / extensions** (bare-string shorthand rejected, strict build-dependency arrays, undeclared compiler-profile rejection, http source rejected, value arrays cannot become table paths, `[lwpt]`/`[format]`/`[generated]` parsing). **LoadLockfile** (missing / corrupt-TOML / no-schema / v1-migration-hint / empty-table / round-trip-fields). **VerifyAgainstLockfile** (matching graph + lock entries: passes silently; tree-hash mismatch / archive-hash mismatch / orphan manifest dep / stale lockfile entry each raise `EVerifyError` naming the dep + the side that mismatched; local-source with empty archive-hash on both sides is the legitimate happy path and must not false-mismatch). Also covers source/version parsing, git ref parsing, include/exclude pruning, path globs, and custom source prefixes. |
| **`source/LWPT.Formatter.Test.pas`** | 24 tests in 4 suites | Running `lwpt format` twice on the same file is a no-op (the contract `--check` rests on). Plus the canonical shapes that previously broke parameter-rename propagation, scope-expansion coverage, and the `.lwpt/**` default-exclusion/explicit-include precedence contract, including case-sensitive include provenance on filesystems that support case-distinct paths. |
| **`source/LWPT.Analysis.Pascal.Test.pas`** | 18 tests in 2 suites | Pins normalized RTL-only tokenization, reserved versus escaped identifiers, byte locations, directive/comment treatment, mode-sensitive active-style nesting with other comment delimiters retained as text, actionable lexical errors, and typed separation of nested routines, declarations, program/routine/assembler bodies, explicit/implicit initialization, and finalization. Explicit initialization/finalization token ranges are disjoint from unit declarations. Representative implementation and local procedural types remain declarations rather than stealing routine bodies, conditional-compilation alternatives stay within their shared routine while conditionally declared helpers retain independent regions, forward composite declarations do not hide later routines, and bodyless routine declarations plus every supported routine kind retain their typed contract. Empty and interface-only sources exercise the parser's early exits. |
| **`source/LWPT.Analysis.Scope.Test.pas`** | 5 tests in 1 suite | Covers recursive root/workspace ownership, globally deepest ownership when discovered project roots overlap, inherited versus replaced `[analysis]` configuration, placeholder-expanded exact build sources, additive include/final exclude behavior, relocated toolkit-state exclusion, deterministic root-relative ordering, strict string arrays, and supported Pascal extensions. |
| **`source/LWPT.Analysis.JSON.Test.pas`** | 4 tests in 1 suite | Pins JSON escaping, fixed byte output, sorted/deduplicated common file/configuration/diagnostic metadata, threshold outcomes, independent command schema versions, caller-owned payloads, and exact one-value validation including malformed, trailing, escaped-string, and excessive-nesting failures. |
| **`source/LWPT.Health.Test.pas`** | 11 tests in 1 suite | Pins straight-line baselines, nested structural/nesting increments, Boolean sequences including `and then`, direct recursion without inherited-dispatch false positives, escaped keyword identifiers, `goto`, case arms, typed handlers with fallback branches, `try/finally`, conditional routine-body alternatives, synthetic executable-section file sums, strict-greater-than maxima, complete violation collection, and canonical hotspot normalization at exact threshold boundaries. |
| **`source/LWPT.Command.Health.Test.pas`** | 3 tests in 1 suite | Covers deterministic human and shared-envelope JSON output, root/workspace limit inheritance and replacement, report-only mode, and strict type/range/unknown-key validation for `[health]`. |
| **`source/LWPT.Duplication.Test.pas`** | 18 tests in 1 suite | Covers Type-2 clones across presentation and consistent identifier/literal renames, inconsistent third-occurrence rejection, maximal non-overlapping multi-occurrence groups including the structural 400-statement repetitive-source result, declaration/executable and nested-routine boundaries, exact minimum inclusion, optional strict thresholds, every duplication-table validation branch, absolute-path source-read diagnostics, workspace policy inheritance/replacement, and final shared-scope exclusion. |
| **`source/LWPT.ManifestEdit.Test.pas`** | 23 tests in 4 suites | Covers dependency insertion, replacement, removal, manifest-line loading, and dependency-name derivation for git-host, local-path, and URL sources. |
| **`source/LWPT.Resolver.Test.pas`** | 7 tests in 1 suite | Pins highest-common-version selection across the complete constraint set, pairwise-overlap/global-empty rejection with every requirer named, literal-tag/SHA and differently named tag unification through advertised commit identity, annotated-tag peeled-commit identity, rejection of equal SemVer precedence mapped to different commits, and literal-branch compatibility. |
| **`source/LWPT.WorkerBudget.Test.pas`** | 22 tests in 1 suite | Self-spawning cross-process coverage for the per-user worker coordinator: two worktree CWDs share a bounded budget, first transactions retry interrupted state-root creation, requests are capped, dead owners are reclaimed, live unreadable/malformed/unknown-schema requests fail closed, repeated release/reacquire cannot jump a waiter, and nested LWPT works at budget 1 through one-shot delegation. Delegation coverage refuses fan-out and token reuse, keeps a child counted after parent death, returns capacity after child failure, and prevents parent release from creating a ghost grant. Failed release writes remain retryable, and two scheduler threads safely share one session. Snapshot assertions cover owner identity, granted capacity, lease age, waiting count, and diagnostics. |
| **`packages/semver/source/Semver.Test.pas`** | 15 tests in 3 suites | `Satisfies` happy path (caret/tilde/exact, complete and partial hyphen ranges, explicit prerelease inclusion, and default prerelease exclusion); `RangeIntersects` matrix the resolver leans on (caret+caret across major boundaries, exact+caret, union ranges); `MaxSatisfying` correctness (highest in range, empty when none match, ignore out-of-range). |
| **`packages/testing/source/TestingPascalLibrary.Test.pas`** | 1 test in 1 suite | The framework canary, lives with the package per ADR-0015. Uses TPL at arm's length (one `Expect<Boolean>(True).ToBe(True)`) so that if TPL itself breaks, this file's failure narrows the blame instead of the suite reporting opaquely. Custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode. |
| **`tests/integration/AddRemove.Test.pas`** | 8 tests in 1 suite | Exercises manifest mutation, install-before-write rollback, source-name derivation errors, update-in-place, and snapshot pruning without touching the local source. A deterministic post-orphan-retention failure proves manifest, lockfile, cfg, and committed module state roll back together. |
| **`tests/integration/BuildClean.Test.pas`** | 4 tests in 1 suite | Covers non-destructive clean behavior, preservation of unrelated files, a missing build directory, and Unix symlink boundaries. |
| **`tests/integration/BuildEntries.Test.pas`** | 13 unconditional tests in 1 suite, plus 1 Unix-only and 1 Darwin-only | Covers named/all-entry selection, fail-fast entry/graph/`--jobs` validation, per-entry compiler-flag forwarding, the Darwin classic-linker path, private entry/mode artifacts, collision-resistant job paths, non-destructive clean behavior, and continuing after per-entry failures. |
| **`tests/integration/InstallLocalDiamond.Test.pas`** | 10 tests in 2 suites | **Full transitive-resolver run** over the canonical diamond graph (root → branch-a + branch-b → leaf-c) with path-syntax local sources (`"../a"`, `"../b"`, `"../c"`) so no network. Asserts lockfile + cfg + tree shape + idempotence + `--frozen` happy path, plus manifest-path invocation from a different cwd. A stripped additive-field fixture proves an unambiguous early schema-v3 lockfile remains valid and byte-identical under frozen verification. **Tamper detection** — edits a file under `.lwpt/modules/leaf-c/`, runs `--frozen`, asserts `EVerifyError` naming the tree-hash mismatch + the dep, and proves lockfile, cfg, full modules hash, and tampered bytes remain unchanged by the failed verification. |
| **`tests/integration/ExtractPathological.Test.pas`** | 14 tests in 2 suites | **Pathological ustar shapes** — baseline short path, > 100-char prefix-split, symlink deferred-link pass. **GNU 'L' long-name** — paths > 255 bytes (past ustar's prefix-split ceiling) wrapped in a GNU `'L'` typeflag header + body carrying the real name; the extractor's pending-long-name buffer carries the name across the header boundary. **Failure modes** — missing archive raises `EExtractError`, truncated gzip leaves Dest empty, invalid gzip magic same contract, tar truncated mid-entry never produces a byte-equal file. |
| **`tests/integration/CLIOptions.Test.pas`** | 10 tests in 1 suite | Spawns `./build/lwpt` with various argv. `--help` + `-h` list every subcommand; unknown verb exits non-zero. Option-parsing regression: `build --mode release` (space-separated value) and `build --mode=release` (equals-separated value) must both parse to "release" and produce the same outcome. Invalid `--mode` value exits non-zero. Completion coverage pins one success line, failure diagnostics plus one failure line, and resolved naming through `lwpt run` aliasing. Scratch project (tiny lwpt.toml + one trivial source) built in-test under `build/tests/tmp/cli-options-e2e/`. |
| **`tests/integration/Duplication.Test.pas`** | 5 tests in 1 suite | Spawns `lwpt duplication` against scratch projects and pins report-only human output, byte-stable shared-envelope JSON, configured threshold failure, actionable invalid-floor diagnostics, and `[analysis].exclude` removal from both scope metadata and clone occurrences. |
| **`tests/integration/CompilerProfiles.Test.pas`** | 15 tests in 1 suite | Uses disposable external, Blaise-CLI, and Lakon-CLI proxies through real `lwpt build` and `lwpt test` subprocesses. Covers success, built-in Blaise dispatch without FPC fallback, a Lakon build consuming a dependency path found only in generated `lwpt.cfg`, entry precedence, identity/version/target failures without fallback, live capability mutation, third-probe target mutation blocking publication, malformed result diagnostics and per-test failure isolation, compile timeout cleanup, artifact confinement and order-independent primary selection, and worker-capacity retention through no-edge entry postbuild, whole-build postbuild, and publication revalidation. |
| **`tests/integration/InstallFetchFailure.Test.pas`** | 20 tests in 3 suites | Spawns `lwpt install` against manifests whose dependency cannot be fetched. **Local source** (3): missing directory → exit non-zero, message names both the dep AND the missing path, `.lwpt/tmp/` empty. **Override contract** (11): `ApplyArchiveFetchOrigin` returns the canonical URL byte for byte when `LWPT_TEST_ARCHIVE_ORIGIN` is unset, swaps only the origin when set, and refuses a remote host, `localhost`, an address outside `127.0.0.0/8` (apart from Windows' non-routable limited-broadcast fallback), `https`, a missing port, a path, and user information. **HTTP failure modes** (6): HTTP 500; an immediate connect failure held in TCP `TIME_WAIT` on Unix and preflighted through HTTPClient's nonblocking Winsock flow on Windows; a redirect that must not escape the fixture; a stalled peer bounded by `LWPT_TEST_ARCHIVE_TIMEOUT_MS`; and a fixed-length body cut short mid-transfer. An independent subprocess watchdog and bounded mock-server join make timeout regressions fail instead of hanging CI. Every case runs offline on Unix and native Windows, asserts the dependency and operation in the message, and proves failure commits no lockfile, cfg, cached archive, or module tree. |
| **`tests/integration/InstallGraphConflict.Test.pas`** | 17 unconditional tests in 1 suite, plus 1 platform-specific link test | Drives complete version/source/policy conflict diagnostics, including a late third source; proves inter-workspace requirements unify with auto-discovery and enforce the workspace version; proves slash-normalized duplicate globs unify while case remains significant; publishes only the exact filtered local snapshot; rejects stale preflight state; preserves committed sentinels; proves rollback retention leaves the published tree readable; recovers deliberately halted publication before tmp cleanup; preserves a Unix symlink or Windows junction across rollback; and exercises both false-return and thrown restore failures to prove transaction rollback and crash recovery continue through every independent entry, preserve the original error, aggregate failures, and retain failed evidence. |
| **`tests/integration/InstallGitGraph.Test.pas`** | 4 tests in 1 suite | Uses deterministic advertised-ref and archive fixtures without network. Covers three-range pairwise-overlap/global-empty rejection; a queue-order regression where an initially unsatisfied shared node waits for a later transitive requirement before emitting its complete diagnostic; immutable tag/SHA identity and frozen ref-mutation immunity; plus a transitive constraint that changes the selected parent and forces round two while asserting one ref advertisement and one unchanged-candidate archive request. |
| **`tests/integration/Init.Test.pas`** | 21 tests in 1 suite | Spawns fresh and adoption `lwpt init` flows in scratch dirs. Fresh-init coverage asserts manifest + hello-world `.pas` + `.gitignore` artefacts, sanitised `program <ident>;` declarations, no lockfile under `--yes`, a runnable built entry, refuse-to-clobber + `--force` semantics, and `.gitignore` idempotence. Adoption coverage pins byte-for-byte manifest preservation, append-only ignore updates derived from declared build output directories, missing-units directory creation, idempotent found/added reporting, mutually exclusive force, missing/invalid manifests, file-vs-directory conflicts, and refusal to write through external or symlinked paths. |
| **`tests/integration/Hooks.Test.pas`** | 10 tests in 1 suite | Spawns build/test flows against scratch manifests with lifecycle hooks. Covers prebuild/postbuild/pretest execution, private-candidate postbuild context, path-token-safe output retargeting, failed-hook publication refusal, staleness-gated skip behavior, and dep-manifest hook dropping. |
| **`tests/integration/InstallNestedManifest.Test.pas`** | 4 tests in 1 suite | Covers nested dependency-manifest discovery, retained repository prefixes, cfg paths, transitive dependencies, and ambiguous equal-depth fallback. |
| **`tests/integration/InstallSymlinkCycle.Test.pas`** | 3 tests in 1 suite | Pins termination, single manifest discovery, and lockfile hashing when local dependency trees contain directory-symlink cycles. |
| **`tests/integration/Repair.Test.pas`** | 5 tests in 1 suite | Spawns `lwpt repair` in scratch projects. Covers clean no-op behavior, stale install-lock removal, `.lwpt/tmp/` cleanup without touching committed module/archive state, failed build-session reclamation, and dead machine-wide worker-request reclamation with diagnostics. |
| **`tests/integration/Scratch.Test.pas`** | 2 tests in 1 suite | Covers unique invocation-private scratch roots plus reaping of dead-owner roots without deleting live-owner state. |
| **`tests/integration/BuildSessions.Test.pas`** | 12 tests in 1 suite | Uses the test executable as a controllable FPC proxy to cover concurrent sessions, stale publication, parallel ready entries, prerequisite publication ordering, `--jobs=1`, failure isolation, deterministic manifest-order results on Unix and Windows, heartbeat observability, and the fail-closed lost-proxy dispatch guard (redacted environment dump, exit 126). |
| **`tests/integration/Agents.Test.pas`** | 14 tests in 1 suite | Covers the `lwpt agents` command-reference generator: section synthesis from the live subcommand registry, `--check` drift detection, marker preservation, and idempotent regeneration. |
| **`tests/integration/Run.Test.pas`** | 6 tests in 1 suite | Spawns `lwpt run` against scratch projects. Covers user-script execution and exit-code propagation, built-in aliasing with flag passthrough, unknown-script errors, list mode omitting retired `export`, and `export` as an allowed user script name. |
| **`tests/integration/TestScheduling.Test.pas`** | 12 tests in 1 suite | Cross-platform subprocess coverage for default overlap, deterministic `--jobs=1` ordering, `--bail=0` override, compile failures counting toward bail, and the amended bail contract: stop new work, terminate and reap active children, and print sorted diagnostics. |
| **`tests/integration/Version.Test.pas`** | 4 tests in 1 suite | Spawns version-reporting forms and verifies output shape plus drift protection against `lwpt.toml`'s `[package].version`. |

### E2E tier

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`tests/e2e/InstallGitHub.E2E.Test.pas`** | 6 tests in 1 suite | Live GitHub fetch of `octocat/Hello-World @ 7fd1a60b…` — the most stable public git ref in existence. Install exits zero, modules tree extracts under `.lwpt/modules/`, archive caches under `.lwpt/archives/<dep>-<ref>.tar.gz`, lockfile records both `archiveHash` and `computedHash`, `--frozen` re-verifies without network, **and** `--frozen` detects an archive byte-tamper (the archive-mismatch path the local-only diamond fixture cannot reach). Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallGitLab.E2E.Test.pas`** | 4 tests in 1 suite | Live GitLab fetch of `gitlab-examples/ci-debug-trace @ dd648b2e48ce6518303b0bb580b2ee32fadaf045`. Validates the GitLab archive-URL pattern in `FetchURL`. Same shape as the GitHub suite: install exit / modules dir / lockfile contents / frozen reverify. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallBitbucket.E2E.Test.pas`** | 4 tests in 1 suite | Live Bitbucket fetch of `atlassian/atlaskit @ d7ac1acad54e…`. Validates the Bitbucket archive-URL pattern. Bitbucket strips the top-level dir hash-suffixed; `StripFirstComponent` handles it. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallDirectArchivesWindows.E2E.Test.pas`** | 3 tests in 1 suite | Windows-only live fetch of direct GitHub codeload + GitLab archive URLs through `lwpt install`. Bypasses source-kind URL construction so the suite specifically exercises the SChannel archive-body read path that previously corrupted `SECBUFFER_EXTRA` leftovers. Honors `LWPT_SKIP_NETWORK=1` and self-skips on non-Windows hosts. |
| **`tests/e2e/InstallScript.E2E.Test.pas`** | 11 tests in 2 suites | Unix-only. Runs `scripts/install.sh` end-to-end against the current **latest** published release — no pinned version constant. The test resolves "latest" from GET `/releases/latest` (which returns the newest non-prerelease-flagged release), passes that tag explicitly to the script, and **derives** the expected `--version` from it (binary == tag, per [ADR-0026](./adr/0026-release-version-stamp-from-tag.md)). The script curls the asset, verifies the checksum, extracts, installs; the test asserts the release resolves without a hidden failure, the install exits zero, the binary lands in `INSTALL_DIR` + is executable, and reports the resolved tag. When `GITHUB_TOKEN` is available the resolver authenticates with a Bearer header. A deterministic fake-curl suite covers authenticated success, explicit no-release 404, narrow connectivity skips, distinct primary/secondary rate-limit skips, hard-failing permission/server responses, unclassified curl failure with captured stderr, and empty/malformed successful responses. This is the suite that would have caught the macOS `.zip` regression (asset-name mismatch → 404 against a release we know exists → fail). Honors `LWPT_SKIP_NETWORK=1`; the live smoke self-skips on non-Unix, on clean connect/DNS failure (transient downtime), on a documented GitHub API rate-limit response, and on an explicit `/releases/latest` 404 until the first non-prerelease release exists (prerelease-flagged `rc.x` are covered by `release.yml`'s per-release install-smoke job instead). Other HTTP/API errors, curl failures not classified as connectivity, and parse failures fail hard. |
| **`packages/httpclient/tests/e2e/TransportSecuritySocket.E2E.Test.pas`** | 3 tests in 1 suite | Linux-only loopback coverage through the HTTPClient package's public API. A caller-owned nonblocking accepted socket drives accept → fragmented read → short write → graceful close and counts every ciphertext byte read before feed. Two separately registered handshake-guard cases use independent connections: a deliberately tiny byte budget proves the over-budget read aborts before those bytes are fed and before the deadline, while a one-byte slow-loris peer proves the monotonic deadline path. The blocking outbound client also verifies that stale OpenSSL error-queue entries are cleared before client I/O. Self-skips on non-Linux hosts. |
| **`tests/e2e/HealthGit.E2E.Test.pas`** | 4 tests in 1 suite | Spawns `lwpt health` against invocation-private projects. A local three-commit repository pins rename-followed changed-line history and byte-stable enriched JSON; a Git-ceiling fixture proves explicit complexity-only degradation and rejects configured hotspot thresholds without history; threshold equality passes and strict excess exits nonzero with the complete JSON violation. Offline on every platform. |

### Supporting infrastructure

- **`packages/httpclient/source/Tests.HTTPMockServer.pas`** — cross-platform `TThread`-backed single-shot HTTP server. Binds an ephemeral loopback port through BSD sockets on Unix or WinSock2 on Windows, serves caller-supplied raw response bytes (no auto-Content-Length, no implicit headers — so pathological shapes are constructible), and dies after one request. Its stop path wakes a blocked accept or shuts down a silent accepted socket before joining the thread; fixture-owned socket, thread, and WinSock-reference counters make lifecycle balance observable to package tests. Tests can select an initial idle period or byte-at-a-time delayed writes for deadline coverage. `TMockRefusedEndpoint` is the supported refused-connection fixture; it holds or preflights the endpoint instead of exposing a released ephemeral port that the kernel could reassign. Builder helpers include `BuildSimpleResponse(body)` and `BuildChunkedResponse(chunks)`.
- **`tests/support/Tests.TarSynth.pas`** — minimal POSIX ustar tarball synthesiser. Builders for regular file entries (with automatic prefix-split for > 100-byte paths), symlink entries, directory entries, **and** GNU `'L'` long-name entries via `MakeGnuLongNameRegularFileEntry`. POSIX checksum computed correctly (the eight-spaces convention). `Gzip(plain)` wraps in a gzip stream. Deliberately scoped — no PaxHeader, GNU `'K'` long-linkname not synthesised (extractor handles both via the same pending-long-name buffer), no sparse files.
- **`tests/support/Tests.LwptSubprocess.pas`** — `TProcess` wrapper for the E2E tier. Spawns `./build/lwpt` with given argv, captures stdout + stderr separately (no merge), supports per-test CWD + env-var overrides, honors `LWPT_SKIP_NETWORK=1` (`SkipNetworkTests` helper). The drain loop reads incrementally while the child runs to avoid pipe-buffer deadlock on long outputs. Also exposes `IsNetworkUnavailable(result)` — the narrow connect/DNS-failure detector the live-network suites use to **skip on transient third-party host downtime** (a `Failed to connect to` / `Failed to resolve host` from HTTPClient) while still failing hard on a content/hash/parse mismatch. See [`ci.md`](./ci.md#transient-host-downtime-skips-it-does-not-fail).
- **`tests/support/Tests.Scratch.pas`** — scratch-directory file helpers shared by the integration + E2E test programs: `WriteTextFile` (write a small text file, creating parent dirs) and `RecursiveDelete` (wipe a tree; symlink-aware — links are unlinked, never followed). Replaces the per-test copy-paste of these two helpers.
- **Testable internals exposure** — `SHA256Hex` remains in `LWPT.Core`; `LoadManifest` and manifest model types live in `LWPT.Manifest`; `LoadLockfile`, `VerifyAgainstLockfile`, and `ExtractArchive` live in `LWPT.Install`. Documented as testable-internal surface, not part of the consumer contract.
- **`--tier` flag** on `lwpt test` — default tier runs unit + integration; `--tier=e2e` adds the network-touching tier.
- **Parallel scheduling controls** — `--jobs=N` caps this invocation within
  the shared worker budget. `[test] bail = N` supplies the project default,
  and `--bail=N` overrides it. Compile and runtime failures both count;
  reaching a positive threshold terminates and reaps active children.
- **Test-artefact placement** — every `lwpt test` invocation owns a unique
  `.lwpt/sessions/<session-id>/` directory. Each test program receives a
  private `-FE`, `-FU`, and executable path below that session. Successful
  sessions are removed; failed sessions remain private and diagnosable until
  `lwpt repair` reclaims them.
- **`tests/support/` auto-discovery** — `LWPT.Command.Testing.CmdTest` adds `tests/support` to the FPC `-Fu`/`-Fi` paths automatically when it exists. `LWPT.Command.Format.CmdFormat` does not walk `tests/` implicitly; the root manifest's `[format].include` globs cover `tests/integration/`, `tests/support/`, and `tests/e2e/` explicitly so project-owned test helpers are held to the same formatter rules as `source/` (see [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md)).

### Counts

| Tier | Files | Test cases |
| --- | --- | --- |
| Unit (`source/*.Test.pas` + package self-tests) | 26 | 472 |
| Integration (`tests/integration/*.Test.pas`) | 22 | 218 |
| E2E (`tests/e2e/*.E2E.Test.pas` + package E2E) | 7 | 35 |
| **Total** | **55** | **725** |

### Planned testing work

| Item | Reason | When |
| --- | --- | --- |
| **~~HTTP-failure tests with test-scoped URL injection~~** | **Solved.** `LWPT_TEST_ARCHIVE_ORIGIN` redirects the archive fetch to a loopback mock server after canonical URL construction, and `tests/integration/InstallFetchFailure.Test.pas` covers HTTP 500, refused connection, a stalled peer, and a fixed-length body cut short. See [issue #34](https://github.com/frostney/lwpt/issues/34). | done |
| **~~Lockfile records host~~** | **Solved.** The v3 lockfile's `source` field is the verbatim manifest string (`gitlab:org/repo`) and `resolvedURL` is the actual archive URL (`https://gitlab.com/...`). Host is recoverable from either. See ADR-0009. | done |
| **Windows install lock + mock server + subprocess paths** | Install locking is covered through `lwpt install` / `lwpt repair` behavior rather than direct lock-type tests. Native WinSock mock-server regression coverage is tracked in [issue #35](https://github.com/frostney/lwpt/issues/35). | [Issue #35](https://github.com/frostney/lwpt/issues/35) |

## TestingPascalLibrary self-test

LWPT (and every other LWPT-using project) consumes `TestingPascalLibrary` via the `testing` workspace package, then uses it to test everything else. If `TestingPascalLibrary` breaks, none of the project's `*.Test.pas` files can tell us so. Mitigation: the `packages/testing/source/TestingPascalLibrary.Test.pas` canary exercises the framework's basic assertions through a one-test suite with custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode — using TPL itself at arm's length. One file; catches the catastrophe.

**Status:** in place; lives in `packages/testing/` per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md).

## Snapshot tests

Out of scope. The formatter's idempotence test catches the same regressions snapshot tests would, with less ceremony.

## Mocking framework

Out of scope. Pascal mocking frameworks (Delphi-Mocks, etc.) are heavyweight and not needed when interface injection or `var`-swap patterns handle every case LWPT has.
