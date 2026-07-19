# Handoff

## Current task

Close the residual adversarial orphan window in issue #73 on the combined
`claude/lwpt-41-observability` branch. Do not commit, push, or open a PR.

## Completed

- Managed children inherit an internal process-tree marker. A top-level Unix
  signal retains the graceful SIGTERM, 250 ms grace, SIGKILL path; a marked
  nested LWPT immediately SIGKILLs every registered group, then polls all of
  them against one shared 100 ms deadline before re-raising the signal.
- Per-tree locks no longer cover sleep/poll intervals, allowing forwarded
  immediate teardown to pre-empt a simultaneous scheduler cancellation.
- Registered-tree termination now aggregates and reports real failures. Direct
  build and test cancellation retain failures as build cancellation errors and
  `tjsWorkerError`, respectively. ADR-0025 records the remaining lack of a
  cross-process acknowledgement channel.
- Signal forwarding is installed only on build/test dispatch paths.
- Windows build/test dispatch installs a minimal `SetConsoleCtrlHandler`
  callback. It signals a Win32 event; an FPC-created thread performs Job Object
  teardown and exits. A Windows-only new-console Ctrl-C regression was added.
- Added the adversarial nested compiler proxy that ignores SIGTERM and asserts
  the compiler is already gone when the outer command returns.
- Added the cross-platform normal-exit regression proving that freeing a
  successful process tree does not kill a still-live descendant.
- Applied the requested naming, environment-helper, manifest/project constant,
  self-pipe index, shared timing-constant, and `const` parameter cleanups.
- Updated ADR-0025. No #41 heartbeat, logging, or summary behavior changed.

## Verification

- FPC verified live: `3.2.2` (`aarch64-darwin`).
- `./build/lwpt install --frozen`: pass; 5 packages and both hashes verified.
- `./build/lwpt format`: pass; 0 of 82 files formatted.
- `./build/lwpt format --check`: pass; all 82 files correctly formatted.
- `./build/lwpt build --clean`: pass with
  `LWPT_WORKER_STATE_DIR=/private/tmp/lwpt-worker-state-4`; summary:
  `1 built, 0 failed, 0 skipped`.
- `./build/lwpt test`: completed with the same writable worker-state override;
  27 passed, 1 failed, 5 skipped. The only failure remains the unrelated
  HTTPClient mock-server suite: all five cases fail at `bind()` because this
  harness forbids listening sockets.
- `TestScheduling.Test`: 12/12 passed, including
  `bail reaps nested LWPT compiler that ignores SIGTERM`.
- `LWPT.Command.Build.Test`: 9/9 passed, including
  `compiler normal exit leaves a live descendant alone`.
- `./build/lwpt --version`: pass (`lwpt 0.2.0`), covering a non-spawning command
  after lazy forwarding installation.
- `git diff --check`: pass.

## Open items

- Run the Windows CI legs to compile and execute the new console-control path;
  no Windows cross-compiler is installed in this worktree.
- Re-run the complete suite in an environment that permits localhost listening
  sockets to obtain a fully green HTTPClient gate. No code change is indicated
  by the observed bind failures.

## Deferred follow-ups

- Typed Windows process-tree state class.
- Convert `TTestJob` to an object and split scheduling integration coverage.
- Share the bounded platform poll loop.
- Add a cross-process cancellation acknowledgement protocol if parents must
  distinguish nested teardown failure from the requested signal exit.
