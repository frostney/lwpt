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

`./build/lwpt test` runs Unit + Integration by default. `./build/lwpt test --tier=e2e` includes the live tier. Positional selectors constrain the run to exact `*.Test.pas` files, recursive directories, or LWPT globs (`*`, `?`, and `**`):

```sh
./build/lwpt test source/LWPT.Core.Test.pas
./build/lwpt test packages/httpclient
./build/lwpt test 'tests/**/Install*.Test.pas' --tier=e2e
```

Quote globs so LWPT—not the shell—matches them consistently. Multiple selectors form a deduplicated union and each must match at least one discovered test program. Discovery and selection freeze before `[pretest]`; the hook can prepare inputs for selected programs but cannot add programs to the current invocation.

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
end.
```

`Run` fails the process by default: a run with any failing test sets
`ExitCode` to 1 itself, so the exit code `lwpt test` reads is always
truthful. (Earlier versions required an explicit
`ExitCode := TestResultToExitCode;` after `Run` — a program that
omitted it exited 0 with failing assertions and its suite was reported
as passing. The function remains exported for harnesses that want the
value explicitly, and the assignment is harmless where it already
exists.)

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
flags = ["-dTEST_FEATURE"]
```

`--bail=N` overrides the manifest for one invocation. A positive threshold
stops new scheduling as soon as that many failures have been observed,
terminates and reaps active compiler/test children, and reports the remaining
programs as cancelled. `--bail=0` always runs the complete queue. CI should
use `--bail=1` for fast feedback.

`flags` is an optional root-manifest array of non-empty compiler-driver
arguments applied, in order, to every test-program compile in both tiers.
Each string is one argument and duplicates remain significant. As with
`[build]` flags, positional/response-file arguments and options that replace
the selected compiler, requested target, or session-private outputs are
rejected. Dependency manifests never contribute test flags, and lifecycle
hook commands do not inherit them.

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

`packages/httpclient/source/Tests.HTTPMockServer.pas` exposes `TMockHTTPServer`, which owns an internal `TThread` over raw sockets. Each test acquires its own ephemeral port via `bind(127.0.0.1, 0)`, captures the complete request through the declared `Content-Length`, serves a single configured response template, and dies. The capture remains byte-safe across multiple 4 KiB reads so tests can assert binary request bodies as well as redirects, content-length lies, chunked edge cases, and partial-content responses.

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
test programs. Counts come from executable registration, not source-text
matching. [ADR-0035](./adr/0035-runtime-test-registration-inventory.md) owns the
protocol and verification contract. `lwpt test --inventory [selector...]`
compiles the selected programs,
sets the framework's inventory environment, and emits one deterministic JSON
value without running test bodies or lifecycle hooks. Projects may opt into
continuous verification by committing `tests/test-inventory.tsv`: ordinary
`lwpt test` runs then compare each successful executable's protocol record with
the platform-specific rule selected from that file. The root inventory names
the six native CI platforms explicitly and uses `*`, `unix/*`, and OS-specific
rules for shared registrations.

The count cells and aggregate table below are generated from that committed
inventory by `instantfpc -Fu./source -Fi./source
scripts/update-test-inventory.pas`; `--check` is the non-mutating CI form. A
stale registration reports the program, platform, expected and observed
suite/case counts, while stale prose reports the update command. Enumeration
still includes E2E programs but exits before their bodies, so producing the
inventory never touches the network.

### Landed

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`packages/httpclient/source/HTTPClient.Test.pas`** (the headline) | 35 tests in 4 suites (Unix); 33 tests in 4 suites (Windows) | Byte-safe request and response regression, mock-server lifecycle, and response resource bounds, substantive on Unix and native Windows. Uses `packages/httpclient/source/Tests.HTTPMockServer.pas` to capture complete requests and serve crafted fixed-length, chunked, close-delimited, idle, and slow-drip responses. Pins byte-perfect embedded-`#0` handling in an 8 KiB-plus POST; authoritative generated `Content-Length` and `Content-Type`; 301/302/303 bodyless-GET redirects; 307/308 method-and-body preservation; unchanged GET/HEAD wire bytes; one-byte segmented response writes; bounded teardown before accept and during a silent accepted connection; deterministic socket/thread/WinSock accounting across repeated success, failure, and unstarted cycles; Unix `select` retry after interruption and client-fd closure on connect-wait failure; exact-limit and over-limit body/header behavior; strict and duplicate response `Content-Length` handling; malformed chunk sizes; architecture-independent rejection of a `7fffffff` chunk whose payload plus CRLF cannot fit the accumulator; fixed-length truncation; a caller-controlled redirect budget; and the monotonic whole-request deadline through both response reads and an idle TLS handshake. Includes a 32 KB response that forces multi-recv and exercises the path where header accumulation has already buffered body bytes. |
| **`packages/httpclient/source/TransportSecurity.Test.pas`** | 38 tests in 1 suite | Pins the PKCS#12 server-accept seam against whichever backend the platform ships — memory-BIO OpenSSL on Unix-not-Darwin, native SChannel on Windows — with an identical observable contract on both: authenticated `Active` state; independently bounded encrypted-input and encrypted-output defaults, minimums, maximums, and invalid configurations; accepted-prefix admission, high/low watermark hysteresis, cumulative accepted/consumed input counters, and exact pending/remaining output state; stable retained-output pointers; internal plaintext retention across a WANT-write retry; server-API bounds clamping; byte-input copying; component-by-component symbolic-link and reparse-point refusal; strict validity, purpose, basic-constraints, key-usage, path-length, chain-coherence, and certificate-cycle failures; acceptance of a conformant leaf that omits basic constraints; explicit permissive self-signed loading with custom flow bounds; reload failure preservation; snapshot lifetime across reload and context close; concurrent begin/abort versus reload; empty, UTF-8, embedded-NUL, oversize, garbage, wrong-pass, missing-path, and leaf-plus-intermediate identities; reusable handshakes; plaintext and partial-ciphertext round trips; stale error queues; `SSL_ERROR_SYSCALL`, peer-`close_notify`, fatal-handshake, and fatal-shutdown poisoning; graceful `close_notify`; the TLS 1.2 floor; operating-system-dependent TLS 1.3 availability; and refused TLS 1.2 renegotiation while TLS 1.3 post-handshake messages continue through SSPI. **Gating is by backend, not by platform.** Ten backend-neutral cases (identity policy, flow configuration, path-link refusal, fatal handshake) need no loopback peer and run wherever a server backend exists. Seventeen cases need the raw in-memory OpenSSL client and run on Unix-not-Darwin only. Ten cases run on Windows only — handshake want-states plus round trip and context reuse; the negotiated protocol ceiling; the bundled intermediate reaching the peer; accepted-prefix admission and counters; retained-output pointer stability and address across partial consumption; the large-write WANT retry; graceful `close_notify`; peer close; and two that pin the persisted-key contract SChannel forces, namely that two concurrently live contexts built from one identity own separate CNG key containers and that a reload publishes a new container while the retained snapshot keeps serving with the old one. So Unix-not-Darwin runs 27 and skips 11; Windows runs 20 and skips 18; Darwin runs the actionable Network.framework stub and records 37 platform skips. Every functional case is pure in-memory and offline, and the Windows leg links no OpenSSL at all. |
| **`packages/cli/source/CLI.Events.Test.pas`** | 5 tests in 1 suite | Pins output-neutral sequencing across serial and concurrent producers, payload ownership after synchronous delivery, nil-payload rejection, and best-effort sink failures that cannot escape or stop the sequence. |
| **`packages/cli/source/CLI.Parser.Test.pas`** | 9 tests in 1 suite | Self-spawns in child mode so `ParseCommandLine` consumes real argv. Covers separated valued short options (including hyphen-leading values), opt-in attached values, repeatable `-Fu` / `-d` values, exact-before-longest-prefix matching for multi-character names, missing and unknown short-option errors, unchanged valueless flags, and both existing long-value forms. |
| **`packages/cli/source/CLI.Subcommands.Test.pas`** | 8 tests in 1 suite | In-process coverage of the subcommand registry: `Count`/`Item` iterate in registration order, `Find` resolves case-insensitively to the same object, each subcommand exposes its option objects, shared flags give existing and future commands independently owned option instances while rejecting command-local name collisions, out-of-range `Item` access raises, and the optional completion callback receives the resolved command name, exit code, and elapsed milliseconds exactly once without being able to replace a nonzero dispatch result — the registry-side complement to the binary-side `CLIOptions.Test.pas`. |
| **`source/LWPT.BuildRequest.Test.pas`** | 12 tests in 1 suite | Pins canonical versioned TOML serialization and parse round-trips for build, probe, result, and capability documents; unsupported-schema failures; ordered extra arguments; compiler-independent target tuples; Windows target-name recognition; explicit incompatibility reasons; and normalized result validation. |
| **`source/LWPT.CompilerDriver.External.Test.pas`** | 10 tests in 1 suite | Runs a real short-lived proxy for probe and compile, proving canonical TOML stdin/stdout, live refresh, bounded raw stderr context, result/exit agreement, primary and extra-artifact confinement, explicit `--clean` rejection, writer-free empty-input cleanup across repeated short-lived children, timeout cleanup when a sleeping child never reads its large stdin, bounded writer cancellation when an escaped descendant retains stdin, retain/discard drainage plus tree termination after capture overflow, and callback streaming that drains without retained-output overflow. |
| **`source/LWPT.CompilerDriver.Delphi.Test.pas`** | 12 tests in 1 suite | Pins the built-in opt-in profile, five verified executable/target tuples, live per-operation identity/version/target probes, bounded failure context, the Delphi 12 version floor, executable/header and requested-target mismatch failures without fallback, neutral argument translation, managed-option rejection, normalized source diagnostics including a zero-exit missing-artifact failure, and exact private artifact renaming without requiring a Delphi installation or license. |
| **`source/LWPT.CompilerRegistry.Test.pas`** | 11 tests in 1 suite | Covers build-entry/project/host/built-in precedence, implicit FPC fallback, built-in Blaise and Lakon selection, the preserved host-command replacement of the Lakon adapter, manifest-over-host authority, case-insensitive caching, out-of-process host command registration, duplicate and protected-built-in-shadow rejection, and configured prefix arguments before adapter arguments. |
| **`source/LWPT.BuildSession.Test.pas`** | 28 tests in 1 suite | Covers unique private paths, bounded collision-resistant keys, atomic/stale publication, parsed-manifest binding, compiler-argument fingerprinting, implicit, declared, and postbuild-hook input hashing, filesystem-identity publication locks, symlinked workspace inputs, and owner-guarded repair. |
| **`source/LWPT.Command.Build.Test.pas`** | 4 tests in 1 suite | Covers compiler-process cancellation with output capture and child reaping, normal-exit descendant handling, non-zero exit-code reporting, and repeated process-tree state teardown without leaking its owned Windows Job Object handle. |
| **`source/LWPT.CompilerDriver.FPC.Test.pas`** | 20 tests in 1 suite | Covers capability-probe caching, target dispatch, timeout cleanup, request compatibility, build/test argument translation, ordered extra-argument forwarding and validation, nil-driver rejection, version failures, stale-artifact classification, structured diagnostics, Windows executable-path normalization, and direct Windows bare-command PATH resolution. |
| **`source/LWPT.CompilerDriver.Blaise.Test.pas`** | 15 tests in 1 suite | Pins the Blaise v0.13.0 identity/help and exact argument fixtures; proves per-operation live probing, the minimum release floor, verified Linux/FreeBSD x86-64 capability filtering, no target fallback, dev/release/clean translation, managed-argument and output-suppression protection, explicit unsupported-feature diagnostics, and normalized diagnostics/artifacts. |
| **`source/LWPT.CompilerDriver.Lakon.Test.pas`** | 17 tests in 1 suite | Pins the released Lakon 0.1.0 identity, help, target, and exact argument fixtures; proves two live probes per capability request, the minimum version, WASI-only capabilities, session-private no-cache translation including generated cfg unit paths with stable deduplication, explicit rejection of native test execution without a host runner, unsupported mode/input/argument failures, and normalized diagnostics/artifacts. The executable itself is replaced by deterministic fixtures in normal CI; compiling with a live Lakon checkout is optional and non-gating. |
| **`source/LWPT.Core.Test.pas`** | 144 tests in 21 suites | **SHA-256 NIST vectors** (empty, "abc", 56-byte block-boundary pad, 1,000,000 "a" multi-block). **HashTree paths** pin the exact nested-tree digest layout, require slash-separated relative paths on every platform, and pin the fold ORDER to an ASCII case-insensitive comparator — AnsiCompareText word-sorts hyphenated names differently on Windows, which reordered byte-identical trees into a different digest. **NormalizeTreeHashContent** folds CRLF content to LF before hashing so a Windows checkout hashes as its LF tree (the content analogue of the path canonicalisation): a CRLF text tree and its LF twin produce one digest, a lone CR survives, empty input stays empty, and NUL-bearing binary passes through verbatim — closing #78's residual that #116 fixed only for path separators. **ConstraintFingerprintForNode** pins the frozen verifier's digest for a fixed constraint set, requires the LF terminator (reproducing the platform Text fold on LF platforms) on every host, and pins the node-level ordinal line sort so a hyphen in a package name cannot reorder requirement lines under a Windows locale word-sort — a lockfile written on one platform verifies on another. **LoadManifest happy path / validation / extensions** now includes shared command/args parsing, complete build-entry targets, strict hook arrays, strict root test flags, and hard migration errors for legacy hook/run `script` and compiler `script`/`executable`, alongside strict build-dependency arrays, undeclared compiler-profile rejection, http source rejection, value arrays that cannot become table paths, and `[lwpt]`/`[format]`/`[generated]` parsing. **LoadLockfile** (missing / corrupt-TOML / no-schema / v1-migration-hint / empty-table / round-trip-fields). **VerifyAgainstLockfile** (matching graph + lock entries: passes silently; tree-hash mismatch / archive-hash mismatch / orphan manifest dep / stale lockfile entry each raise `EVerifyError` naming the dep + the side that mismatched; local-source with empty archive-hash on both sides is the legitimate happy path and must not false-mismatch). Also covers source/version parsing, git ref parsing, include/exclude pruning, path globs, and custom source prefixes. |
| **`source/LWPT.Manifest.Schema.Test.pas`** | 7 tests in 1 suite | Pins registry completeness and defaults, case-sensitive known sections versus case-insensitive task reservations, strict validation through `LoadManifest`, root-only suppression, permissive malformed-value compatibility, and strict unknown-key policy. The strict-field case and the Agents integration schema line exercise the same registry entry from parser and renderer. |
| **`source/LWPT.Formatter.Test.pas`** | 25 tests in 4 suites | Running `lwpt format` twice on the same file is a no-op (the contract `--check` rests on). Plus the canonical shapes that previously broke parameter-rename propagation, scope-expansion coverage, and the `.lwpt/**` default-exclusion/explicit-include precedence contract, including case-sensitive include provenance on filesystems that support case-distinct paths. |
| **`source/LWPT.Analysis.Pascal.Test.pas`** | 18 tests in 2 suites | Pins normalized RTL-only tokenization, reserved versus escaped identifiers, byte locations, directive/comment treatment, mode-sensitive active-style nesting with other comment delimiters retained as text, actionable lexical errors, and typed separation of nested routines, declarations, program/routine/assembler bodies, explicit/implicit initialization, and finalization. Explicit initialization/finalization token ranges are disjoint from unit declarations. Representative implementation and local procedural types remain declarations rather than stealing routine bodies, conditional-compilation alternatives stay within their shared routine while conditionally declared helpers retain independent regions, forward composite declarations do not hide later routines, and bodyless routine declarations plus every supported routine kind retain their typed contract. Empty and interface-only sources exercise the parser's early exits. |
| **`source/LWPT.Analysis.Scope.Test.pas`** | 5 tests in 1 suite | Covers recursive root/workspace ownership, globally deepest ownership when discovered project roots overlap, inherited versus replaced `[analysis]` configuration, placeholder-expanded exact build sources, additive include/final exclude behavior, relocated toolkit-state exclusion, deterministic root-relative ordering, strict string arrays, and supported Pascal extensions. |
| **`source/LWPT.Analysis.JSON.Test.pas`** | 4 tests in 1 suite | Pins JSON escaping, fixed byte output, sorted/deduplicated common file/configuration/diagnostic metadata, threshold outcomes, independent command schema versions, caller-owned payloads, and exact one-value validation including malformed, trailing, escaped-string, and excessive-nesting failures. |
| **`source/LWPT.Health.Test.pas`** | 11 tests in 1 suite | Pins straight-line baselines, nested structural/nesting increments, Boolean sequences including `and then`, direct recursion without inherited-dispatch false positives, escaped keyword identifiers, `goto`, case arms, typed handlers with fallback branches, `try/finally`, conditional routine-body alternatives, synthetic executable-section file sums, strict-greater-than maxima, complete violation collection, and canonical hotspot normalization at exact threshold boundaries. |
| **`source/LWPT.TestInventory.Test.pas`** | 6 tests in 1 suite | Pins platform-rule specificity, ambiguity failures, canonical documentation convergence, and the actionable stale-documentation path. |
| **`source/LWPT.Command.Health.Test.pas`** | 3 tests in 1 suite | Covers deterministic human and shared-envelope JSON output, root/workspace limit inheritance and replacement, report-only mode, and strict type/range/unknown-key validation for `[health]`. |
| **`source/LWPT.Duplication.Test.pas`** | 18 tests in 1 suite | Covers Type-2 clones across presentation and consistent identifier/literal renames, inconsistent third-occurrence rejection, maximal non-overlapping multi-occurrence groups including the structural 400-statement repetitive-source result, declaration/executable and nested-routine boundaries, exact minimum inclusion, optional strict thresholds, every duplication-table validation branch, absolute-path source-read diagnostics, workspace policy inheritance/replacement, and final shared-scope exclusion. |
| **`source/LWPT.ManifestEdit.Test.pas`** | 23 tests in 4 suites | Covers dependency insertion, replacement, removal, manifest-line loading, and dependency-name derivation for git-host, local-path, and URL sources. |
| **`source/LWPT.OutputRenderer.Test.pas`** | 1 test in 1 suite | Proves the fixed-capacity silent emergency ring preserves the exact most-recent 1 MiB tail across chunked wraparound without shifting retained bytes on append. |
| **`source/LWPT.Resolver.Test.pas`** | 7 tests in 1 suite | Pins highest-common-version selection across the complete constraint set, pairwise-overlap/global-empty rejection with every requirer named, literal-tag/SHA and differently named tag unification through advertised commit identity, annotated-tag peeled-commit identity, rejection of equal SemVer precedence mapped to different commits, and literal-branch compatibility. |
| **`source/LWPT.Observability.Test.pas`** | 6 tests in 1 suite | Pins typed job, heartbeat, diagnostic, byte-safe child-output, command-terminal, truncation, and capture-degradation payloads, including source/correlation tags, ordinary/protected/terminal retention classes, the nonzero outcome invariant for failed jobs, zero-exit failure normalization, and preservation of genuine child exits. |
| **`source/LWPT.WorkerBudget.Test.pas`** | 22 tests in 1 suite | Self-spawning cross-process coverage for the per-user worker coordinator: two worktree CWDs share a bounded budget, first transactions retry interrupted state-root creation, requests are capped, dead owners are reclaimed, live unreadable/malformed/unknown-schema requests fail closed, repeated release/reacquire cannot jump a waiter, and nested LWPT works at budget 1 through one-shot delegation. Delegation coverage refuses fan-out and token reuse, keeps a child counted after parent death, returns capacity after child failure, and prevents parent release from creating a ghost grant. Failed release writes remain retryable, and two scheduler threads safely share one session. Snapshot assertions cover owner identity, granted capacity, lease age, waiting count, and diagnostics. |
| **`packages/semver/source/Semver.Test.pas`** | 15 tests in 3 suites | `Satisfies` happy path (caret/tilde/exact, complete and partial hyphen ranges, explicit prerelease inclusion, and default prerelease exclusion); `RangeIntersects` matrix the resolver leans on (caret+caret across major boundaries, exact+caret, union ranges); `MaxSatisfying` correctness (highest in range, empty when none match, ignore out-of-range). |
| **`packages/testing/source/TestingPascalLibrary.Test.pas`** | 2 tests in 1 suite | The framework canary, lives with the package per ADR-0015. Uses TPL at arm's length (one `Expect<Boolean>(True).ToBe(True)`) so that if TPL itself breaks, this file's failure narrows the blame instead of the suite reporting opaquely. Custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode. |
| **`tests/integration/AddRemove.Test.pas`** | 8 tests in 1 suite | Exercises manifest mutation, install-before-write rollback, source-name derivation errors, update-in-place, and snapshot pruning without touching the local source. A deterministic post-orphan-retention failure proves manifest, lockfile, cfg, and committed module state roll back together. |
| **`tests/integration/BuildClean.Test.pas`** | 4 tests in 1 suite | Covers non-destructive clean behavior, preservation of unrelated files, a missing build directory, and Unix symlink boundaries. |
| **`tests/integration/BuildEntries.Test.pas`** | 15 tests in 1 suite (Darwin); 14 tests in 1 suite (Linux); 13 tests in 1 suite (Windows) | Covers named/all-entry selection, fail-fast entry/graph/`--jobs` validation, per-entry compiler-flag forwarding, the Darwin classic-linker path, private entry/mode artifacts, collision-resistant job paths, non-destructive clean behavior, and continuing after per-entry failures. |
| **`tests/integration/InstallLocalDiamond.Test.pas`** | 10 tests in 2 suites | **Full transitive-resolver run** over the canonical diamond graph (root → branch-a + branch-b → leaf-c) with path-syntax local sources (`"../a"`, `"../b"`, `"../c"`) so no network. Asserts lockfile + cfg + tree shape + idempotence + `--frozen` happy path, plus manifest-path invocation from a different cwd. A stripped additive-field fixture proves an unambiguous early schema-v3 lockfile remains valid and byte-identical under frozen verification. **Tamper detection** — edits a file under `.lwpt/modules/leaf-c/`, runs `--frozen`, asserts `EVerifyError` naming the tree-hash mismatch + the dep, and proves lockfile, cfg, full modules hash, and tampered bytes remain unchanged by the failed verification. |
| **`tests/integration/ExtractPathological.Test.pas`** | 14 tests in 2 suites | **Pathological ustar shapes** — baseline short path, > 100-char prefix-split, symlink deferred-link pass. **GNU 'L' long-name** — paths > 255 bytes (past ustar's prefix-split ceiling) wrapped in a GNU `'L'` typeflag header + body carrying the real name; the extractor's pending-long-name buffer carries the name across the header boundary. **Failure modes** — missing archive raises `EExtractError`, truncated gzip leaves Dest empty, invalid gzip magic same contract, tar truncated mid-entry never produces a byte-equal file. |
| **`tests/integration/CLIOptions.Test.pas`** | 30 tests in 1 suite | Spawns `./build/lwpt` with various argv. `--help` + `-h` list every subcommand; unknown verb exits non-zero. Option parsing covers both `--mode` value shapes and invalid values. Test selection covers exact files, recursive directories, `*`/`?`/`**` globs, deduplicated unions, tier preservation, rejection before `pretest` or session creation, and proof that a `pretest`-generated program is excluded from the frozen inventory. Completion coverage pins ordinary success and failure on stderr, including resolved naming through `lwpt run` aliasing. Silent-mode coverage verifies the shared option on every command, exactly-one-line success, ordered diagnostic/result replay, the `--verbose` conflict, resolved aliases, successful child suppression across a later compiler failure, failed run-task replay, failed format-check and no-build evidence after unrelated warnings, and rejection of interactive `init --silent`. Scratch project (tiny manifest, source, tests, and commands) is built under an invocation-private test root. |
| **`tests/integration/Duplication.Test.pas`** | 6 tests in 1 suite | Spawns `lwpt duplication` against scratch projects and pins report-only human output, byte-stable shared-envelope JSON, configured threshold failure, silent replay of stdout-only failure evidence, actionable invalid-floor diagnostics, and `[analysis].exclude` removal from both scope metadata and clone occurrences. |
| **`tests/integration/CompilerProfiles.Test.pas`** | 18 tests in 1 suite | Uses disposable external, Blaise-CLI, and Lakon-CLI proxies through real `lwpt build` and `lwpt test` subprocesses. Covers success, configured built-in prefix ordering for probe and compile, Lakon cfg paths, entry precedence, identity/version/target failures without fallback, an explicit complete target tuple reaching probe and compile unchanged, generic non-host test rejection, live capability mutation, malformed results, timeout cleanup, artifact confinement, and publication revalidation. |
| **`tests/integration/InstallFetchFailure.Test.pas`** | 20 tests in 3 suites | Spawns `lwpt install` against manifests whose dependency cannot be fetched. **Local source** (3): missing directory → exit non-zero, message names both the dep AND the missing path, `.lwpt/tmp/` empty. **Override contract** (11): `ApplyArchiveFetchOrigin` returns the canonical URL byte for byte when `LWPT_TEST_ARCHIVE_ORIGIN` is unset, swaps only the origin when set, and refuses a remote host, `localhost`, an address outside `127.0.0.0/8` (apart from Windows' non-routable limited-broadcast fallback), `https`, a missing port, a path, and user information. **HTTP failure modes** (6): HTTP 500; an immediate connect failure held in TCP `TIME_WAIT` on Unix and preflighted through HTTPClient's nonblocking Winsock flow on Windows; a redirect that must not escape the fixture; a stalled peer bounded by `LWPT_TEST_ARCHIVE_TIMEOUT_MS`; and a fixed-length body cut short mid-transfer. An independent subprocess watchdog and bounded mock-server join make timeout regressions fail instead of hanging CI. Every case runs offline on Unix and native Windows, asserts the dependency and operation in the message, and proves failure commits no lockfile, cfg, cached archive, or module tree. |
| **`tests/integration/InstallGraphConflict.Test.pas`** | 20 tests in 1 suite | Drives complete version/source/policy conflict diagnostics, including a late third source; proves inter-workspace requirements unify with auto-discovery and enforce the workspace version; proves slash-normalized duplicate globs unify while case remains significant; publishes only the exact filtered local snapshot; rejects stale preflight state; preserves committed sentinels; proves rollback retention leaves the published tree readable; recovers deliberately halted publication before tmp cleanup; preserves a Unix symlink or Windows junction across rollback; and exercises both false-return and thrown restore failures to prove transaction rollback and crash recovery continue through every independent entry, preserve the original error, aggregate failures, and retain failed evidence. |
| **`tests/integration/InstallGitGraph.Test.pas`** | 4 tests in 1 suite | Uses deterministic advertised-ref and archive fixtures without network. Covers three-range pairwise-overlap/global-empty rejection; a queue-order regression where an initially unsatisfied shared node waits for a later transitive requirement before emitting its complete diagnostic; immutable tag/SHA identity and frozen ref-mutation immunity; plus a transitive constraint that changes the selected parent and forces round two while asserting one ref advertisement and one unchanged-candidate archive request. |
| **`tests/integration/Init.Test.pas`** | 21 tests in 1 suite | Spawns fresh and adoption `lwpt init` flows in scratch dirs. Fresh-init coverage asserts manifest + hello-world `.pas` + `.gitignore` artefacts, sanitised `program <ident>;` declarations, no lockfile under `--yes`, a runnable built entry, refuse-to-clobber + `--force` semantics, and `.gitignore` idempotence. Adoption coverage pins byte-for-byte manifest preservation, append-only ignore updates derived from declared build output directories, missing-units directory creation, idempotent found/added reporting, mutually exclusive force, missing/invalid manifests, file-vs-directory conflicts, and refusal to write through external or symlinked paths. |
| **`tests/integration/Hooks.Test.pas`** | 11 tests in 1 suite | Spawns build/test flows against scratch manifests with lifecycle hooks. Covers direct command execution, proof that bare `.pas` strings do not select InstantFPC, prebuild/postbuild/pretest execution, private-candidate context, path-token-safe output retargeting, failed-hook publication refusal, staleness-gated skips, and dependency-hook dropping. |
| **`tests/integration/InstallNestedManifest.Test.pas`** | 4 tests in 1 suite | Covers nested dependency-manifest discovery, retained repository prefixes, cfg paths, transitive dependencies, and ambiguous equal-depth fallback. |
| **`tests/integration/InstallSymlinkCycle.Test.pas`** | 3 tests in 1 suite | Pins termination, single manifest discovery, and lockfile hashing when local dependency trees contain directory-symlink cycles. |
| **`tests/integration/Repair.Test.pas`** | 6 tests in 1 suite | Spawns `lwpt repair` in scratch projects. Covers clean no-op behavior, stale install-lock removal, `.lwpt/tmp/` cleanup without touching committed module/archive state, failed build-session reclamation, and dead machine-wide worker-request reclamation with diagnostics. |
| **`tests/integration/Scratch.Test.pas`** | 2 tests in 1 suite | Covers unique invocation-private scratch roots plus reaping of dead-owner roots without deleting live-owner state. |
| **`tests/integration/BuildSessions.Test.pas`** | 15 tests in 1 suite | Uses the test executable as a controllable FPC proxy to cover concurrent sessions, stale publication, parallel ready entries, prerequisite publication ordering, `--jobs=1`, failure isolation, deterministic manifest-order results on Unix and Windows, heartbeat observability including shared wait cadence, state-correct skipped-build diagnostics, and the fail-closed lost-proxy dispatch guard (redacted environment dump, exit 126). Unexpected observable-build exits report both FPC `TProcess` status views plus read-only worker/session-root state so an intermittent failure can be attributed without guessing from interleaved output. |
| **`tests/integration/Agents.Test.pas`** | 15 tests in 1 suite | Covers the `lwpt agents` command-reference generator: section synthesis from the live subcommand and manifest-schema registries, schema-specific `--check` drift detection, marker preservation, and idempotent regeneration. |
| **`tests/integration/Run.Test.pas`** | 9 tests in 1 suite | Spawns `lwpt run` against scratch projects. Covers direct run-task execution and exact exit propagation, built-in aliasing with flag passthrough, unknown-task errors, list mode, retired `export` as an allowed task name, strict glob staleness and unmatched-input diagnostics, fresh-task skipping, and rejection of invocation-time arguments. |
| **`tests/integration/TestScheduling.Test.pas`** | 24 tests in 1 suite (Unix); 21 tests in 1 suite (Windows) | Cross-platform subprocess coverage for default overlap, deterministic `--jobs=1` ordering, `--bail=0` override, compile failures counting toward bail, and the amended bail contract: stop new work, fan cancellation to active siblings under one absolute deadline, terminate and reap active children, and print sorted diagnostics. Unix runs native SIGINT/SIGTERM forwarding regressions, rejects forged acknowledgement channels backed by regular files or wrong-direction pipes, and bounds control reads across data, EOF, and silent peers; Windows runs matching Ctrl-C/Ctrl-Break Job Object reaping regressions. A deterministic spawn barrier proves managed and unmanaged process creation share the inheritance-critical window. A nested owner-and-descendant fixture proves successful hop-by-hop acknowledgement and propagated `FAILED`; separate fixtures pin the post-acknowledgement reap window, an already-empty registered tree as a successful no-op, missing terminal acknowledgement, and bounded incremental/trailing protocol framing. An output-capture fixture proves the original process failure survives a secondary delegation-cleanup failure. |
| **`tests/integration/TestFlags.Test.pas`** | 3 tests in 1 suite | Spawns `lwpt test` against scratch manifests to prove ordered root `[test].flags` reach default- and E2E-tier compiles, LWPT-managed output arguments are rejected, and direct pretest commands inherit neither the flags nor any undeclared arguments. |
| **`tests/integration/Version.Test.pas`** | 4 tests in 1 suite | Spawns version-reporting forms and verifies output shape plus drift protection against `lwpt.toml`'s `[package].version`. |

### E2E tier

| File | Suites / tests | What it asserts |
| --- | --- | --- |
| **`tests/e2e/InstallGitHub.E2E.Test.pas`** | 6 tests in 1 suite | Live GitHub fetch of `octocat/Hello-World @ 7fd1a60b…` — the most stable public git ref in existence. Install exits zero, modules tree extracts under `.lwpt/modules/`, archive caches under `.lwpt/archives/<dep>-<ref>.tar.gz`, lockfile records both `archiveHash` and `computedHash`, `--frozen` re-verifies without network, **and** `--frozen` detects an archive byte-tamper (the archive-mismatch path the local-only diamond fixture cannot reach). Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallGitLab.E2E.Test.pas`** | 4 tests in 1 suite | Live GitLab fetch of `gitlab-examples/ci-debug-trace @ dd648b2e48ce6518303b0bb580b2ee32fadaf045`. Validates the GitLab archive-URL pattern in `FetchURL`. Same shape as the GitHub suite: install exit / modules dir / lockfile contents / frozen reverify. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallBitbucket.E2E.Test.pas`** | 4 tests in 1 suite | Live Bitbucket fetch of `atlassian/atlaskit @ d7ac1acad54e…`. Validates the Bitbucket archive-URL pattern. Bitbucket strips the top-level dir hash-suffixed; `StripFirstComponent` handles it. Honors `LWPT_SKIP_NETWORK=1`. |
| **`tests/e2e/InstallDirectArchivesWindows.E2E.Test.pas`** | 3 tests in 1 suite | Windows-only live fetch of direct GitHub codeload + GitLab archive URLs through `lwpt install`. Bypasses source-kind URL construction so the suite specifically exercises the SChannel archive-body read path that previously corrupted `SECBUFFER_EXTRA` leftovers. Honors `LWPT_SKIP_NETWORK=1` and self-skips on non-Windows hosts. |
| **`tests/e2e/InstallScript.E2E.Test.pas`** | 11 tests in 2 suites | Unix-only. Runs `scripts/install.sh` end-to-end against the current **latest** published release — no pinned version constant. The test resolves "latest" from GET `/releases/latest` (which returns the newest non-prerelease-flagged release), passes that tag explicitly to the script, and **derives** the expected `--version` from it (binary == tag, per [ADR-0026](./adr/0026-release-version-stamp-from-tag.md)). The script curls the asset, verifies the checksum, extracts, installs; the test asserts the release resolves without a hidden failure, the install exits zero, the binary lands in `INSTALL_DIR` + is executable, and reports the resolved tag. When `GITHUB_TOKEN` is available the resolver authenticates with a Bearer header. A deterministic fake-curl suite covers authenticated success, explicit no-release 404, narrow connectivity skips, distinct primary/secondary rate-limit skips, hard-failing permission/server responses, unclassified curl failure with captured stderr, and empty/malformed successful responses. This is the suite that would have caught the macOS `.zip` regression (asset-name mismatch → 404 against a release we know exists → fail). Honors `LWPT_SKIP_NETWORK=1`; the live smoke self-skips on non-Unix, on clean connect/DNS failure (transient downtime), on a documented GitHub API rate-limit response, and on an explicit `/releases/latest` 404 until the first non-prerelease release exists (prerelease-flagged `rc.x` are covered by `release.yml`'s per-release install-smoke job instead). Other HTTP/API errors, curl failures not classified as connectivity, and parse failures fail hard. |
| **`packages/httpclient/tests/e2e/TransportSecuritySocket.E2E.Test.pas`** | 0 tests in 0 suites (Darwin, Windows); 3 tests in 1 suite (Linux) | Linux-only loopback coverage through the HTTPClient package's public API. A caller-owned nonblocking accepted socket drives accept → fragmented read → short write → graceful close and counts every ciphertext byte read before feed. Two separately registered handshake-guard cases use independent connections: a deliberately tiny byte budget proves the over-budget read aborts before those bytes are fed and before the deadline, while a one-byte slow-loris peer proves the monotonic deadline path. The blocking outbound client also verifies that stale OpenSSL error-queue entries are cleared before client I/O. Self-skips on non-Linux hosts. |
| **`tests/e2e/HealthGit.E2E.Test.pas`** | 4 tests in 1 suite | Spawns `lwpt health` against invocation-private projects. A local three-commit repository pins rename-followed changed-line history and byte-stable enriched JSON; a Git-ceiling fixture proves explicit complexity-only degradation and rejects configured hotspot thresholds without history; threshold equality passes and strict excess exits nonzero with the complete JSON violation. Offline on every platform. |

### Supporting infrastructure

- **`packages/httpclient/source/Tests.HTTPMockServer.pas`** — cross-platform `TThread`-backed single-shot HTTP server. Binds an ephemeral loopback port through BSD sockets on Unix or WinSock2 on Windows, captures request headers plus the full declared body across repeated receives, serves caller-supplied raw response bytes (no auto-Content-Length, no implicit headers — so pathological shapes are constructible), and dies after one request. Its stop path wakes a blocked accept or shuts down a silent accepted socket before joining the thread; fixture-owned socket, thread, and WinSock-reference counters make lifecycle balance observable to package tests. Tests can select an initial idle period or byte-at-a-time delayed writes for deadline coverage. `TMockRefusedEndpoint` is the supported refused-connection fixture; it holds or preflights the endpoint instead of exposing a released ephemeral port that the kernel could reassign. Builder helpers include `BuildSimpleResponse(body)` and `BuildChunkedResponse(chunks)`.
- **`tests/support/Tests.TarSynth.pas`** — minimal POSIX ustar tarball synthesiser. Builders for regular file entries (with automatic prefix-split for > 100-byte paths), symlink entries, directory entries, **and** GNU `'L'` long-name entries via `MakeGnuLongNameRegularFileEntry`. POSIX checksum computed correctly (the eight-spaces convention). `Gzip(plain)` wraps in a gzip stream. Deliberately scoped — no PaxHeader, GNU `'K'` long-linkname not synthesised (extractor handles both via the same pending-long-name buffer), no sparse files.
- **`tests/support/Tests.LwptSubprocess.pas`** — `TProcess` wrapper for the E2E tier. Spawns `./build/lwpt` with given argv, captures stdout + stderr separately (no merge), supports per-test CWD + env-var overrides, honors `LWPT_SKIP_NETWORK=1` (`SkipNetworkTests` helper). The drain loop reads incrementally while the child runs to avoid pipe-buffer deadlock on long outputs. Also exposes `IsNetworkUnavailable(result)` — the narrow connect/DNS-failure detector the live-network suites use to **skip on transient third-party host downtime** (a `Failed to connect to` / `Failed to resolve host` from HTTPClient) while still failing hard on a content/hash/parse mismatch. See [`ci.md`](./ci.md#transient-host-downtime-skips-it-does-not-fail).
- **`tests/support/Tests.Scratch.pas`** — scratch-directory file helpers shared by the integration + E2E test programs: `WriteTextFile` (write a small text file, creating parent dirs) and `RecursiveDelete` (wipe a tree; symlink-aware — links are unlinked, never followed). Replaces the per-test copy-paste of these two helpers.
- **Testable internals exposure** — `SHA256Hex` remains in `LWPT.Core`; `LoadManifest` and manifest model types live in `LWPT.Manifest`; `LoadLockfile`, `VerifyAgainstLockfile`, and `ExtractArchive` live in `LWPT.Install`. Documented as testable-internal surface, not part of the consumer contract.
- **`--tier` flag** on `lwpt test` — default tier runs unit + integration; `--tier=e2e` adds the network-touching tier.
- **Positional test selectors** — exact `*.Test.pas` files, recursive
  directories, and LWPT globs constrain the frozen discovered inventory.
  Selectors are project-root-relative, strict, unioned, and deduplicated;
  they never bypass `--tier`.
- **Parallel scheduling controls** — `--jobs=N` caps this invocation within
  the shared worker budget. `[test] bail = N` supplies the project default,
  and `--bail=N` overrides it. Compile and runtime failures both count;
  reaching a positive threshold terminates and reaps active children.
- **Test-artefact placement** — every `lwpt test` invocation owns a unique
  resolved project-owned build-session directory. Each test program receives a
  private `-FE`, `-FU`, and executable path below that session. Successful
  sessions discard private compiler jobs and hooks but retain stable logs and
  completed state for diagnosis. Failed sessions retain their private
  diagnostics. `lwpt repair` reclaims inactive sessions after their owner guard
  is absent.
- **`tests/support/` auto-discovery** — `LWPT.Command.Testing.CmdTest` adds `tests/support` to the FPC `-Fu`/`-Fi` paths automatically when it exists. `LWPT.Command.Format.CmdFormat` does not walk `tests/` implicitly; the root manifest's `[format].include` globs cover `tests/integration/`, `tests/support/`, and `tests/e2e/` explicitly so project-owned test helpers are held to the same formatter rules as `source/` (see [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md)).

### Counts

<!-- lwpt:test-inventory-counts:begin -->
| Tier | Files | Registered test cases |
| --- | ---: | --- |
| Unit | 31 | 541 Unix / 539 Windows |
| Integration | 23 | 266 Darwin / 265 Linux / 261 Windows |
| E2E | 7 | 32 Darwin, Windows / 35 Linux |
| **Total** | **61** | **839 Darwin / 841 Linux / 832 Windows** |
<!-- lwpt:test-inventory-counts:end -->

## TestingPascalLibrary self-test

LWPT (and every other LWPT-using project) consumes `TestingPascalLibrary` via the `testing` workspace package, then uses it to test everything else. If `TestingPascalLibrary` breaks, none of the project's `*.Test.pas` files can tell us so. Mitigation: the `packages/testing/source/TestingPascalLibrary.Test.pas` canary exercises the framework's basic assertions through a one-test suite with custom exit codes (10/11/12/13/14) for each plausible TPL initialisation failure mode — using TPL itself at arm's length. One file; catches the catastrophe.

**Status:** in place; lives in `packages/testing/` per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md).

## Snapshot tests

Out of scope. The formatter's idempotence test catches the same regressions snapshot tests would, with less ceremony.

## Mocking framework

Out of scope. Pascal mocking frameworks (Delphi-Mocks, etc.) are heavyweight and not needed when interface injection or `var`-swap patterns handle every case LWPT has.
