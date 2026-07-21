# Route FPC compilation through a neutral compiler-driver seam

ADR-0022 established `TLWPTBuildRequest`, compiler capabilities, and
`TLWPTBuildResult`, but deliberately left FPC argument construction and output
interpretation in the build and test commands. That split produced two
different FPC argument builders, kept capability matching out of production,
and left FPC-specific failure heuristics in the build scheduler. This ADR
completes the deferred driver workstream from
[issue #43](https://github.com/frostney/lwpt/issues/43).

`TLWPTCompilerDriver` owns five operations: `ProbeCapabilities`,
`BuildArguments`, `ExecutableName`, `ClassifyFailure`, and `NormalizeResult`.
`TLWPTFPCCompilerDriver` is the only implementation. Both manifest-target and
test/Windows-hook compilation construct a neutral request, probe and validate
it with `BuildRequestIsCompatible`, then ask the driver for the executable and
arguments. The execution-only invocation options alongside the request select
either the manifest-build or standalone-Pascal-source argument profile plus an
incremental or forced-rebuild policy; they do not add FPC fields to the
versioned request.

Capability discovery is an on-demand dispatch probe for the requested target.
Non-host architectures and operating systems add FPC's `-P` and `-T` switches,
then one `-iV -iTO -iTP` invocation reports the selected compiler version and
target. Results and failures are cached per target for the lifetime of the
driver shared by one build or test invocation. The driver interface requires
implementations to support concurrent worker calls, and the FPC driver's cache
serializes probes and returns defensive capability copies. Publication deliberately
bypasses that cache and repeats the probe, preserving ADR-0020's protection
against a compiler change while a target is building. A missing executable,
missing cross compiler, unexpected target, or incompatible version fails with
a compiler-and-requirement error; there is no fallback.

FPC output normalization produces `TLWPTBuildResult` diagnostics with severity,
message, and source path/line/column when FPC supplies an origin. The caller
retains the original byte-for-byte output for ordered log replay. Failure
classification owns the FPC exit summary and stale-artifact retry heuristic.
`TLWPTCompilerProcess` retains process-tree execution/cancellation
responsibility and now receives the driver-selected executable. Unix
InstantFPC script execution remains outside the driver; Windows hook
compilation uses the ordinary FPC driver path before the compiled script runs.

## Considered Options

- **Move only capability probing and leave both argument builders in place.**
  Rejected because the seam would not own compilation and the two flag sets
  would keep drifting.
- **Defer result normalization.** Rejected because a driver that returns only
  raw text does not implement ADR-0022's normalized-result half.
- **Route lifecycle script execution through the compiler driver.** Rejected:
  the driver compiles Pascal, while InstantFPC cache/execution behavior is a
  script-runner concern.
- **Enumerate installed `ppcross*` binaries.** Rejected because names and
  installation layouts are platform-specific; FPC's own `-P` dispatch is the
  authoritative availability check.

## Consequences

- FPC remains LWPT's implementation compiler and only compiler driver. There
  is no manifest compiler-selection surface, registry, fallback driver, or
  cross-compiler installer.
- FPC capabilities advertise executable and library outputs. Unit output is
  not advertised because FPC's `-o` switch names a program or library artifact,
  not a compiled unit output.
- Native publication fingerprints keep the same serialized inputs and
  compiler executable. The version identity now comes from the target-dispatch
  probe rather than a separate host-only `fpc -iV`; cross builds therefore
  fingerprint the compiler that actually handled their target.
- `FPC_TARGET_OS` now participates in FPC dispatch through `-T` when it differs
  from the host instead of changing fingerprint metadata alone.
- Configuration-fragment handling remains intentionally different at the
  invocation-option level: builds pass `@lwpt.cfg`, while test and Windows hook
  compilation expand it for cross-platform response-file compatibility. The
  FPC driver owns both translations.
