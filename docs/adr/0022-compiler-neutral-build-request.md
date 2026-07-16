# Define a versioned compiler-neutral build request and target model

## Executive Summary

- Build intent is represented by `TLWPTBuildRequest`, not compiler arguments.
- The target tuple belongs to the request and is independent of compiler and
  host identity.
- Compiler capabilities and build results use normalized, versioned structures.
- FPC remains LWPT's only compiler adapter and LWPT's implementation compiler.

## Context

Build and test compilation already carried the same concepts in different
forms: source and search paths in FPC argument construction, target OS/CPU and
compiler identity in publication fingerprints, and private output paths in
build sessions. That made compiler selection, host platform, desired target,
and FPC execution details look like one concern. It also left no stable
contract for future drivers to consume without copying FPC-shaped assumptions.

The contract must cover current LWPT build and test compilation while allowing
the same desired target to be considered by different compatible compilers. A
single compiler must also be able to advertise multiple native and cross
targets without duplicating compiler registrations. Unsupported combinations
must fail explicitly; silent compiler or target fallback is prohibited.

## Decision

`LWPT.BuildRequest` owns three schema-versioned structures:

- A build request contains compiler identity, version constraint or selected
  version identity, a target tuple, source set and entry point, output kind,
  build mode, defines, unit/include paths, resources, and private output
  locations.
- Compiler capabilities contain one compiler identity/version and arrays of
  supported target tuples, output kinds, and modes.
- A build result contains success, normalized diagnostics, artifacts, and
  dependency metadata.

Target tuples require OS and architecture and may additionally constrain ABI
and execution environment. Empty optional target dimensions are wildcards in
compatibility checks; OS and architecture always match exactly. Compiler ID,
version identity or SemVer constraint, output kind, and mode must also match.

Build requests have a canonical TOML serialization with a fixed field order
and preserved array order. Schema version 1 is the only accepted request,
result, and capability version; unknown versions fail with a message naming
both the received and supported versions. The versioned fixture under
`tests/fixtures/build-request/v1/` pins the wire representation.

Current `lwpt build` and `lwpt test` paths construct and validate the neutral
request before their existing FPC argument construction runs. Publication
fingerprints embed the canonical request but keep compiler executable and
public-output generation as publication concerns. This issue does not add a
driver registry or move FPC CLI construction; that belongs to the compiler
driver workstream.

## Considered options

- **Document a future structure without using it.** Rejected because it would
  drift immediately and would not demonstrate that current build/test needs
  are covered.
- **Introduce the neutral model and use it at existing build/test seams.**
  Chosen. It establishes a live interface while preserving current FPC
  behavior.
- **Route compilation through a full driver interface now.** Rejected as the
  next architectural step; combining it here would blur the request contract
  with driver discovery and FPC adaptation.

## Consequences

- Compiler and target identities are no longer conflated in publication data.
- A target tuple can be submitted unchanged to different compiler drivers, and
  one compiler capability record can expose multiple native/cross tuples.
- Deterministic serialization changes are schema changes and require a new
  versioned fixture.
- FPC behavior, flags, build modes, and LWPT's own compiler remain unchanged.
- Future drivers translate the request into compiler-specific invocation and
  normalize their outputs back into `TLWPTBuildResult`; they do not add
  compiler-specific fields to the neutral request.
