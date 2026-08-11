# Freeze test selection before `pretest`

## Status

Accepted for LWPT 0.6.0.

## Context

`lwpt test` resolves its complete discovered inventory and any positional test selectors before running `[pretest]`. This deliberately supersedes ADR-0011's `pretest` → discovery ordering: a test invocation must have a stable, reviewable scope before lifecycle commands can mutate the project, so `pretest` may prepare inputs for the frozen programs but cannot add programs to that invocation.

## Decision

Freeze the complete discovered test inventory and resolve all positional selectors before invoking `[pretest]`.

## Consequences

- `lwpt test [selector...]` accepts project-root-relative `*.Test.pas` files, directories (recursive), and LWPT globs (`*`, `?`, and `**`). Multiple selectors form a deduplicated union.
- Every selector is strict. Absolute paths, project escapes, non-test files, missing literals, empty directories, and globs matching no discovered test fail before a build session or hook starts.
- Selection never changes tier policy. An E2E program selected without `--tier=e2e` remains skipped.
- With no selectors, LWPT still selects the complete discovered inventory; only the lifecycle ordering changes.
- Projects that generated test programs in `[pretest]` must generate them earlier or invoke the generator before `lwpt test`. Existing `[pretest]` commands may continue generating fixtures, units, and other inputs consumed by already-discovered programs.

Path selectors were chosen over name-substring filtering because filesystem paths identify one stable test program, while the existing LWPT glob dialect provides recursive grouping without introducing another pattern language. Shell expansion is not involved: selectors arrive as ordinary process arguments and LWPT performs matching consistently on every platform.
