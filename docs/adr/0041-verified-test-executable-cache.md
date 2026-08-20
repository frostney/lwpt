# Cache verified test executables without caching execution

## Status

Accepted.

## Context

ADR-0020 made every test compilation invocation-private. ADR-0037 later made
verified build-entry artifacts reusable, while explicitly leaving test
execution outside its decision. Recompiling an unchanged `*.Test.pas` program
on every command, watch cycle, agent, and equivalent worktree wastes compiler
work, but reusing a prior pass or failure would make the current test result
untrustworthy.

## Decision

Normal `lwpt test` invocations capture the ADR-0037 neutral compilation
fingerprint with a distinct `test-program` operation identity. The versioned
fingerprint covers the neutral test request and output identity; test source
and transitive unit, include, workspace, module, manifest, lockfile, and
configuration content; effective test flags; the selected compiler driver,
live version, target, and normalized arguments; and compiler-relevant
environment. Equivalent project-relative paths are independent of the
checkout's absolute location. Build entries use their separate `build-entry`
identity and cannot collide with test programs.

After a successful, current compilation, LWPT packages every artifact reported
by the compiler driver into a deterministic bounded artifact-set object. Its
relative paths, kinds, modes, lengths, and bytes are stored through the same
verified build-result manifest, immutable object store, producer lease, cache
budget, eviction, and repair machinery as build entries. A hit verifies that
object and expands the complete set only below the active test job's private
session root. Paths are validated before materialization, and the reconstructed
driver result must still satisfy the compiler-neutral artifact contract.

Compilation reuse never becomes execution reuse. Every hit launches the
materialized executable in the current invocation. Inventory mode launches it
with a fresh inventory authorization and queries registrations again. Exit
status, pass/fail state, stdout, stderr, timing, inventory output, and other
runtime state are never stored. Failed, cancelled, stale, incomplete, corrupt,
or unverifiable compiles never publish a reusable reference.

`lwpt test --no-cache` bypasses both lookup and storage and performs a real
compilation. Cache absence, corruption, or budget refusal remains a
deterministic compile path rather than a correctness dependency. Waiters for
the same fingerprint release their machine worker lease while the shared
producer lease is held, then reacquire capacity before accepting a verified
result or taking over compilation.

## Consequences

- Unchanged selected tests compile once across commands and equivalent
  worktrees, while each invocation still runs them.
- Source, dependency, toolchain, target, flag, configuration, or relevant
  environment changes produce a distinct miss.
- Multi-file compiler outputs are reused atomically as one verified set;
  writable session intermediates that the driver does not report remain
  private and disposable.
- The command surface, cache root, project storage, dependencies, selection,
  scheduling, bail, inventory, and native-target policies do not change.
- There is still no cache of test results.
