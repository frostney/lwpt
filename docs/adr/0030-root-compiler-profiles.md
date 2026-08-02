# Select compiler drivers through root-owned profiles

ADR-0022 defined the versioned compiler-neutral request/result contract and
ADR-0029 routed FPC through a driver seam. This ADR completes the compiler
foundation from [issue #44](https://github.com/frostney/lwpt/issues/44) by
making that seam selectable without granting dependencies execution policy.

The root manifest owns named profiles under
`[compiler.profiles.<name>]`. A profile declares a `driver`, an optional
version constraint, and either an external `executable` or an InstantFPC
`script`. `[compiler] default` selects the project profile; a build entry may
override it with `compiler = "<profile>"`. Selection precedence is build entry,
project default, embedding-host default, then built-in FPC. Tests use the same
resolved project context. Dependency manifests cannot register profiles or
select a compiler.

Embedding hosts may register in-process factories by neutral driver ID. Host
factories are API registration, not manifest extension: a dependency cannot
register or shadow them, and the built-in `fpc` ID cannot be shadowed. One
driver instance per selected profile is cached for an invocation and shared by
its workers. A factory returns a fresh object owned by the selection; LWPT
validates that object's driver identity before accepting it and frees rejected
objects and accepted objects exactly once. The configured version constraint
is enforced independently against the factory object's live capabilities.

External drivers use one short-lived child process for each `probe` or
`compile` operation. LWPT sends the applicable versioned canonical TOML
document on stdin, reads the canonical capability or build-result document
from stdout until EOF, and preserves stderr as raw human-facing diagnostics.
Exit status and the structured document must agree. Every process is owned by
a `TLWPTProcessTree`. One bounded duplex runner writes stdin while draining
stdout and stderr, retains at most 16 MiB from each stream, discards later
bytes while continuing to drain, and terminates the whole process tree on
timeout or capture failure. Stdin pumping is cancellable and its join is
bounded even when an escaped descendant retains the read end. Probes have a 30-second
deadline. Compiles default to 30 minutes and may be configured with
`LWPT_COMPILER_TIMEOUT_MS`; they cannot wait forever. There is no daemon
lifecycle or implicit fallback to another profile.

Cached capabilities may shape scheduling, but every concrete build or test
compile refreshes them immediately before request translation. Build
publication refreshes them again while worker capacity covers every per-entry
and whole-build postbuild path, fingerprint revalidation, and atomic
publication. Any refreshed incompatibility in compiler identity, version,
target, output kind, or build mode fails closed and leaves the candidate
private.

External stdout is machine protocol only. Invalid documents, missing results,
exit/result disagreement, and invalid artifact reports retain a bounded tail
of raw stderr in the surfaced error and the session log. A successful result
must report the requested primary artifact with its exact kind and path; every
other reported artifact must remain within the request's private executable,
unit, object, or resource output roots.

The compiler-neutral request intentionally excludes execution-only rebuild
policy. The built-in FPC driver translates `--clean` to its forced-rebuild
flag; the version-1 external protocol rejects `--clean` explicitly rather than
silently compiling incrementally. A later protocol version may add an explicit
rebuild-policy field when an external backend contract requires it.

## Considered Options

- **Allow dependency manifests to contribute profiles.** Rejected because
  resolving a package must not expand the root project's executable policy.
- **Infer compiler selection from target tuples.** Rejected because compiler
  and target are independent choices and fallback would hide configuration
  errors.
- **Use a persistent driver daemon.** Rejected because it adds lifecycle,
  framing, cancellation, and stale-state failure modes without evidence that
  process startup is the limiting cost.
- **Put external-driver fields directly on every build entry.** Rejected
  because named profiles keep executable policy centralized and reusable.

## Consequences

- Existing manifests remain unchanged and select built-in FPC.
- External driver executables and scripts are root-authorized project inputs;
  relative paths resolve from the project root.
- `lwpt build` and `lwpt test` share selection and protocol behavior while
  lifecycle-hook compilation remains on the built-in FPC path.
- Unit paths expanded from `lwpt.cfg` are included in neutral test requests,
  so an external driver receives the same complete search surface as FPC.
- Compiler profiles provide the stable foundation for adding concrete backend
  adapters without adding compiler-specific fields to build requests.
