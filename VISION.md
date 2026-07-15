# Vision

## Mission

Make Object Pascal projects reproducible, portable, and safe to operate
concurrently through one manifest and one self-contained toolkit, whether
driven by a human or an agent.

## Product direction

LWPT provides one Pascal-native executable and one `lwpt.toml` manifest for
the recurring work around an Object Pascal project: dependency management,
building, formatting, testing, repair, and declared project scripts. The
package manager remains the foundation: it resolves a project into committed,
verifiable state that the rest of the toolkit consumes.

LWPT serves human developers and AI agents as first-class users. Its commands
must therefore be deterministic, observable, safe to run concurrently, and
clear about progress and failure. Long-running work must not look hung, and
one process must not be able to corrupt or overwrite another process's work.

LWPT itself remains built with FreePascal. Consumer projects should be able to
select a compiler independently from their target platform, including
cross-compilation, without LWPT silently changing that selection. The
compiler-neutral build direction is tracked as product work; it is not a claim
about the current implementation.

An Object Pascal project must remain buildable and distributable without
depending on an LWPT-operated central service. Package distribution may use
self-hosted origins and mirrors, but the core workflow retains its committed,
zero-install foundation.

## Principles

- **One manifest, one toolkit.** Project behavior belongs in `lwpt.toml` and
  the self-contained `lwpt` executable, not in a collection of external build
  wrappers.
- **Reproducibility over convenience.** Lockfiles, hashes, committed dependency
  state, explicit inputs, and atomic publication make the same project state
  produce the same result.
- **Humans and agents get the same contract.** Commands expose progress,
  bounded work, actionable failures, and stable machine-observable behavior.
- **Concurrency must be safe by construction.** Parallelism is useful only
  when sessions, intermediate outputs, caches, and final publication cannot
  collide.
- **Compiler and target are independent choices.** A build request describes
  the compiler profile and the target separately; unsupported combinations
  fail rather than falling back to a different compiler.
- **Decentralisation is a reliability feature.** Registries are independently
  operable origins and mirrors, not a mandatory global service or namespace.
- **Pascal-native and dependency-light.** LWPT remains a single FreePascal
  binary with no external runtime required by consumers.
- **Current truth beats aspirational documentation.** Documentation describes
  shipped behavior. Planned behavior belongs in investigated GitHub issues or
  a user-confirmed implementation idea until it is implemented.

## What LWPT is not

LWPT is not an IDE plugin, a system-wide package installer, a compiler, or a
general build orchestrator for non-Object-Pascal sources. It does not operate a
required central registry, and it does not evaluate architectural drift in
consumer projects. Architecture conformance for LWPT itself is a project
release concern.

## Related documents

- [`AGENTS.md`](./AGENTS.md) is the operating contract for contributors and
  agents.
- [`DEFINITION_OF_READY.md`](./DEFINITION_OF_READY.md) defines when work is
  understood well enough to implement.
- [`DEFINITION_OF_DONE.md`](./DEFINITION_OF_DONE.md) defines when a change is
  complete and releasable.
- [`docs/architecture.md`](./docs/architecture.md) describes the implemented
  architecture.
- [`docs/adr/`](./docs/adr/) records decisions when they are made during
  implementation.
