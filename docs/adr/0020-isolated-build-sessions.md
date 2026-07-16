# Isolate compiler output by invocation and publish builds atomically

## Executive Summary

- **Every build and test invocation owns a unique private session.** Compiler
  outputs cannot collide across concurrent processes or worktrees.
- **Build publication is short, locked, and revalidated.** LWPT hashes the exact
  manifest snapshot it parses and publishes only while all declared inputs
  still match.
- **Ownership remains observable for the full session lifecycle.** Failed,
  stale, and interrupted work remains private for `lwpt repair`; successful
  cleanup retains its OS guard until the private contents are gone.

Each `lwpt build` and `lwpt test` invocation owns a unique project-local
session under `.lwpt/sessions/`. Compiler executable, unit, object, resource,
and hook-compilation outputs are written only below that session. A successful
build captures a versioned compiler-neutral publication fingerprint before
compilation, acquires a short lock derived from the requested public output,
captures the fingerprint again, and atomically replaces the public executable
only when the two fingerprints match. Failed, stale, or interrupted candidates
remain private; `lwpt repair` reclaims inactive sessions while conservatively
retaining sessions whose recorded process is alive.

## Considered options

- **Lock the public output for the full compile.** This prevents corruption but
  serialises identical builds for their entire duration and makes future
  parallel scheduling wait behind compiler work. Rejected.
- **Publish immutable generations behind a `current` link or launcher.** This
  gives clean generation semantics but changes the manifest output contract
  and introduces platform-specific link/launcher behavior. Rejected for this
  issue; reusable generations belong to build-result caching.
- **Private sessions plus short, revalidated publication.** Chosen. It keeps
  compilation independent, preserves exact manifest output paths, and
  concentrates coordination in the brief operation that mutates public state.

## Consequences

- `--clean` means a forced compile in already-fresh private staging. It no
  longer sweeps `build/`, deletes the previous successful executable, prunes
  legacy target directories, or touches source-adjacent compiler artifacts.
- The publication fingerprint is schema version 1 and describes publication
  validity, not reusable-cache identity. Its compiler-neutral structure records
  the selected compiler identity, executable, and live version alongside the
  source/output request, prior public-output content, and target dimensions.
  The source directory and declared search roots are content-hashed while
  excluding
  `.lwpt/sessions/` and every declared build output, so a root-level unit path
  still tracks compiler inputs without fingerprinting private staging or an
  unrelated target's publication. Explicit file inputs remain hashed even when
  they are also declared outputs. Directory symlinks and junctions, including
  workspace packages below `.lwpt/modules/`, are followed; physical directory
  identities prevent link cycles from recursing indefinitely.
  The prior output makes a completed concurrent publication invalidate later
  candidates captured from the older generation. Complete reusable-cache
  contributions remain owned by the later cache workstream.
- Lifecycle hooks still run in manifest order. Per-target postbuild hooks run
  against the private candidate before publication and receive
  `LWPT_BUILD_OUTPUT`, `LWPT_BUILD_PUBLIC_OUTPUT`, and `LWPT_BUILD_TARGET`.
  Existing `{item.output}` references in hook fields are retargeted to the
  candidate only when the expanded path is a complete path token; related
  paths such as `build/app.json` remain unchanged. Hook definitions, scripts,
  and declared inputs are publication inputs. Failed hooks prevent
  publication. Whole-build postbuild runs after every selected target
  compiled and its private hook succeeded, with complete-token public-output
  references retargeted across all staged candidates. It is the final success
  gate before any output is published; artifact transformations still belong
  in per-target postbuild hooks. Arbitrary
  hook filesystem side effects are not sandboxed, but hook
  compilation is session-private:
  Windows compiles directly below the hook root, while Unix gives InstantFPC
  a cache below that same session. Job and compiler-cache directory names use
  bounded readable prefixes plus hashes of their full identities, avoiding
  sanitisation collisions and excessive path lengths.
- Publication requires a same-filesystem atomic replacement. If the platform
  refuses replacement, including a locked destination, LWPT leaves the prior
  public artifact intact and retains the candidate for diagnosis.
- The fingerprint binds the exact manifest bytes loaded before parsing to the
  parsed request. A manifest change during or after parsing refuses compilation
  or publication instead of combining new on-disk bytes with stale parsed
  configuration.
- Output-specific lock files use the physical destination-parent identity and
  filesystem-appropriate filename casing. They are stable names backed by an
  OS-held advisory
  byte-range lock plus a keyed in-process critical section. This matters on
  Unix, where `fcntl` locks are process-scoped and do not serialize threads in
  the same LWPT process. OS ownership ends automatically when the handle closes
  or the process exits; no contender or repair operation unlinks another
  generation's lock file. Each session also holds an OS owner guard for its
  lifetime; `lwpt repair` reclaims only unlocked sessions and fails closed for
  malformed state while that guard remains held.
- `[version]` include generation stages beside the include and uses a true
  same-filesystem replacement, so simultaneous
  builds observe either the previous complete include or the next complete
  include, never a truncated intermediate write.
