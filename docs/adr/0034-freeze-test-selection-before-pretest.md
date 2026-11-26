# Freeze test selection before `pretest`

## Status

Accepted for LWPT 0.6.0. The tier-policy consequence was superseded by
[ADR-0042](./0042-keep-test-grouping-in-userland.md). Amended in place: the
discovered inventory excludes Git-ignored paths, and a selector naming one is
refused.

## Context

`lwpt test` resolves its complete discovered inventory and any positional test selectors before running `[pretest]`. This deliberately supersedes ADR-0011's `pretest` → discovery ordering: a test invocation must have a stable, reviewable scope before lifecycle commands can mutate the project, so `pretest` may prepare inputs for the frozen programs but cannot add programs to that invocation.

## Decision

Freeze the complete discovered test inventory and resolve all positional selectors before invoking `[pretest]`.

The discovered inventory is every `*.Test.pas` below the manifest's unit roots and the project root, except under `.lwpt/`, `build/`, and `.git/`, and except paths that the project's Git ignore rules ignore. LWPT reads those rules from the ignore files itself (every `.gitignore` from the enclosing worktree root down, plus that worktree's `info/exclude`) and never runs `git`, so discovery behaves the same in a project that is not a checkout. Selectors narrow this inventory and never widen it.

## Consequences

- `lwpt test [selector...]` accepts project-root-relative `*.Test.pas` files, directories (recursive), and LWPT globs (`*`, `?`, and `**`). Multiple selectors form a deduplicated union.
- Every selector is strict. Absolute paths, project escapes, non-test files, missing literals, empty directories, and globs matching no discovered test fail before a build session or hook starts.
- Every selected program runs regardless of its path; the runner has no test-group taxonomy.
- With no selectors, LWPT still selects the complete discovered inventory; only the lifecycle ordering changes.
- Scratch programs in ignored folders, such as reproductions under `.agent/`, are not discovered, so they cannot fail a run or make a committed test inventory stale. A test program that a generator writes into an ignored directory is not discovered either; it must live in a path that is not ignored or be re-included with a negated pattern.
- A file or directory selector that names an ignored path is refused before a build session or hook starts, and the error names the ignore file, line, and pattern. Allowing it would let a selector add a program the complete inventory does not hold, which breaks the rule that every selector constrains the frozen inventory, and the explicit run would then disagree with the committed test inventory. Refusing it with the deciding pattern also tells the user how to re-include the program.
- Discovery reads ignore files, not Git's index, so a tracked file that matches an ignore pattern is skipped too. Per-user configuration (`core.excludesFile`, `core.ignorecase`) is not read, so the result depends only on the project's own files, and matching is case-sensitive.
- The project root and the directories above it are never judged: a project kept in an ignored folder still discovers its own tests, while the patterns of the `.gitignore` files above the project root still apply to its contents. An ignore file that exists but cannot be read stops the command, where Git only warns, so a missing rule never lets ignored programs run.
- Projects that generated test programs in `[pretest]` must generate them earlier or invoke the generator before `lwpt test`. Existing `[pretest]` commands may continue generating fixtures, units, and other inputs consumed by already-discovered programs.

Path selectors were chosen over name-substring filtering because filesystem paths identify one stable test program, while the existing LWPT glob dialect provides recursive grouping without introducing another pattern language. Shell expansion is not involved: selectors arrive as ordinary process arguments and LWPT performs matching consistently on every platform.
