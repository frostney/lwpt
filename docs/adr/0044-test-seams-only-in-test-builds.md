# Test fetch and fault seams exist only in test builds

## Executive Summary

- Every toolkit-read `LWPT_TEST_*` variable, and every fault-injection
  branch behind one, compiles only under the `INSTALL_TESTING` define.
- The `lwpt-testing` build entry produces `build/lwpt-testing` with that
  define, and a `[pretest]` hook keeps it current. `build/lwpt` and release
  binaries contain neither the seams nor their names.
- Only test runs that set a seam variable spawn the test binary
  (`RunLwptTesting`). Every other run exercises `build/lwpt`.
- `release.yml` refuses to publish a binary that contains any marker in
  `tests/test-seam-markers.txt`. `TestSeamIsolation.Test.pas` proves each
  marker exists only in the test build and that `build/lwpt` ignores the
  variables.

Issue [#303](https://github.com/frostney/lwpt/issues/303) found that the shipped
`lwpt` binary honoured `LWPT_TEST_GIT_FIXTURE_DIR` (ref listing and archive
fetches read from local files) and `LWPT_TEST_ARCHIVE_ORIGIN` (archive fetches
rewritten to a loopback origin). Any environment that project tooling can set,
such as an `.envrc` or a CI step, could therefore substitute dependency
contents in a real install. The same binary also read install fault-injection
variables (`LWPT_TEST_FAIL_AFTER_LOCK_WRITE`, `LWPT_TEST_CORRUPT_ROLLBACK_FOR`,
`LWPT_TEST_CRASH_DEPENDENCY_PRODUCER`, and similar), one of which deliberately
corrupts rollback state.

## Decision

Every toolkit-read `LWPT_TEST_*` variable is compiled only when the
`INSTALL_TESTING` define is set. A binary built without it contains neither the
seam code nor the variable names, and ignores the variables.

- The fetch seams (`LWPT_TEST_GIT_FIXTURE_DIR`, `LWPT_TEST_ARCHIVE_ORIGIN`,
  `LWPT_TEST_ARCHIVE_TIMEOUT_MS`) sit inside `{$IFDEF INSTALL_TESTING}` blocks
  in `LWPT.GitProtocol` and `LWPT.Install`.
- Each fault-injection branch (a halt, an injected exception, or a corrupted
  rollback copy) is itself inside an `{$IFDEF INSTALL_TESTING}` block. It reads
  its variable through `TestSeamValue` in `LWPT.Core`, which exists only in a
  test build.
- The root manifest keeps LWPT's existing build model
  ([ADR-0005](./0005-self-host-build.md)): a second `[build]` entry,
  `lwpt-testing`, compiles `source/lwpt.pas` with `flags = ["-dINSTALL_TESTING"]`
  into `build/lwpt-testing`. Build sessions compile each entry separately, so
  the two flavours never share unit output.
- A root `[pretest]` hook runs `./build/lwpt build lwpt-testing` before every
  `lwpt test`, so programs that spawn the binary never run a stale test build.
  The build-result cache ([ADR-0037](./0037-verified-build-result-cache.md))
  reduces an unchanged tree to a verification pass.
- `[test].flags` also passes `-dINSTALL_TESTING`, so test programs that link
  the install units in process keep the pure seam functions.
- A test run that sets a seam variable spawns the test binary through
  `Tests.LwptSubprocess.RunLwptTesting`, and only that run does. Every other
  run in the same program keeps spawning `./build/lwpt`, the binary users run.
- The `lwpt` build entry, `scripts/bootstrap.pas`, and the cross-compile
  commands in `ci.yml`, `pr.yml`, and `release.yml` never pass the define.
  `tests/test-seam-markers.txt` lists the `LWPT_TEST_` prefix and every fault
  name. `release.yml` refuses to publish a staged binary that contains any of
  them. `tests/integration/TestSeamIsolation.Test.pas` provides the positive
  canary: every marker is present in `build/lwpt-testing` and absent from
  `build/lwpt`. It also runs each seam against both binaries and asserts that
  only `build/lwpt-testing` honours it.

## Considered options

- **Keep the seams and narrow their inputs.** The archive-origin override
  already accepted only a numeric loopback origin, which was the earlier
  argument for shipping it. Narrowing still lets a set variable replace the
  bytes that an install publishes, and the git fixture seam cannot be narrowed
  in any useful way. Rejected.
- **Keep fault branches compiled and only disable the variable reads.** This
  would ignore the variables, but deliberate halt and corruption code would
  still ship, and the release check could only look for the variable prefix.
  Rejected.
- **Replace the seams with an injected transport and run install in process.**
  This is the cleanest seam, but it would rewrite every integration program
  that tests the real CLI subprocess. It would also stop exercising argument
  parsing, exit codes, and on-disk effects through the binary users run.
  Rejected for this change. The define keeps those programs unchanged apart
  from the binary their seam runs select.
- **Build the test binary inside each test program or in CI steps.** Per-program
  builds race each other and duplicate compiler flags. CI-only steps leave
  local `lwpt test` runs without the binary and require extra steps on every
  cross-compiled leg. The `[pretest]` hook covers every route through the
  command that already runs the tests.

## Consequences

- `build/lwpt-testing` is a development and test artefact only. It is never
  staged, packaged, or published.
- Every `lwpt test` of the root project first runs a cached `lwpt build
  lwpt-testing`, including on CI legs that test a cross-compiled `build/lwpt`.
  Those legs build the test flavour natively with the runner's FPC, which the
  test programs already need.
- A new toolkit-side test seam must sit behind `INSTALL_TESTING`, and its name
  must be added to `tests/test-seam-markers.txt`. The canary then fails if the
  name is missing from the test build or present in `build/lwpt`.
