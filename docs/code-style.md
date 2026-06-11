# Code style

Naming, file layout, formatter rules, manifest-declared formatter scope, line-ending normalisation. The conventions inherited from `native-nostalgia-stack` plus the LWPT-specific additions that crystallised over the spike-to-production work.

## Executive Summary

- **Identifiers are PascalCase, no underscores, no abbreviations.** Industry-standard acronyms (HTTP, JSON, UUID, **LWPT**) stay as-is. Type prefix `T`, exception `E`, interface `I`, private field `F`, parameter `A` (when ≥ 2 letters).
- **The project name lives in two constants.** `PROGRAM_NAME = 'lwpt'` (lowercase Unix convention; derives filenames and shell commands) and `PROJECT_NAME = 'LWPT'` (uppercase acronym in prose). See [ADR-0001](./adr/0001-program-name-as-constant.md). Never hardcode either spelling.
- **LWPT-internal units use the dotted `LWPT.<Subsys>.pas` form.** Workspace packages under `packages/<name>/source/` follow their own naming (see [`packages.md`](./packages.md)). The "Packages own their contents" Hard Constraint in `AGENTS.md` keeps the root LWPT formatter + reviewers out of package source.
- **`lwpt format` is the canonical formatter.** No-flag invocation rewrites in place; `--check` is the CI / pre-commit mode. Rules are encoded in the Pascal source of `LWPT.Formatter`, not in a config file.
- **Formatter scope is manifest-declared** (`[package].units` + `[format].include` minus `[format].exclude`). Globs supported; recursion is explicit via `**`. See [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md) for the resolution algorithm. Root LWPT's `[format].include` covers `tests/integration/`, `tests/support/`, `tests/e2e/`, and every workspace package (`packages/**/*.{pas,inc}`) so the canonical style applies across the monorepo. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md)'s root-owns-unless-overridden model, a workspace package can opt out by declaring its own `[format]` section in `packages/<name>/lwpt.toml`.
- **Line endings: LF everywhere, trailing whitespace stripped.** The two scope additions from Q8; both are zero-controversy.

## Naming

- **Classes** `T<Name>`. Interfaces `I<Name>`. Exceptions `E<Name>`. LWPT's error hierarchy is `ELWPTError` + `EFetchError`, `EVerifyError`, `EExtractError`, `ELockfileError`, `EManifestError`, `EConcurrencyError`.
- **Private fields** carry the `F` prefix (`FIndex`, `FRoot`, `FText`).
- **Parameters** with two or more letters carry the `A` prefix (`AName`, `AValue`, `AFilePath`). Single-letter parameters (`A`, `B`, `E`, `T`) keep their name as-is.
- **Functions, procedures, methods, locals, constants** are `PascalCase`. No underscores. No numeric suffixes (`PrimaryScope`, not `Scope1`).
- **No abbreviations.** Use full words for class, function, method, and type names. Industry-standard acronyms — `HTTP`, `JSON`, `ISO`, `UUID`, `URL`, `AST`, **`LWPT`** — stay as-is.

## Project-name conventions

LWPT-specific extension of the rule above:

- The project's prose name is **LWPT** (uppercase acronym).
- The project's binary, filenames, environment variables, and shell commands are **lowercase `lwpt`** (Unix convention).
- Both spellings are declared once in `LWPT.Core` as `PROJECT_NAME` and `PROGRAM_NAME` respectively, and every derived literal threads through one of them: `MANIFEST_FILE = PROGRAM_NAME + '.toml'`, error prefixes via `PROGRAM_NAME + ' install: '`, banners via `PROJECT_NAME`. Never write `'lwpt'` or `'LWPT'` as a literal anywhere except in those two declarations.

The reasoning is in [ADR-0001](./adr/0001-program-name-as-constant.md).

## Unit naming

- **Project-owned units** use the dotted form: `LWPT.<Subsys>.pas` (or `LWPT.<Subsys>.<Subsys>.pas` for nested namespaces). The acronym stays uppercase per the rule above. Examples: `LWPT.Core.pas`, `LWPT.Formatter.pas`, `LWPT.GitProtocol.pas`. **CLI-layer units intentionally skip the `LWPT.` prefix** (`CLI.Options`, `CLI.Parser`, `CLI.Help`, `CLI.Subcommands`, `CLI.Prompts`) because they live in the `packages/cli/` workspace package — designed to graduate as a standalone reusable package (see ADR-0006 + ADR-0014).
- **Workspace packages** under `packages/<name>/source/` follow each package's own naming conventions; the root LWPT manifest does not dictate. Today's names (`HTTPClient`, `TransportSecurity`, `FileUtils`, `StringBuffer`, `TestingPascalLibrary`, `CLI.Options`, `CLI.Parser`, `CLI.Help`, `CLI.Subcommands`, `CLI.Prompts`, `Semver`, `TOML`, `OrderedStringMap`, `BaseMap`) reflect LWPT-canonical choices per [ADR-0017](./adr/0017-packages-lwpt-canonical.md) — the `CLI` namespace stripped `TGoccia` prefixes + dropped dead code, `Semver` renamed from `Goccia.Semver` + inlined the one needed `MAX_SAFE_INTEGER` constant, `Platform` (in `source/`) renamed from `Goccia.Platform`, TOML refactored to its current class-based parser shape. See [`packages.md`](./packages.md) for the full set + divergence-vs-GocciaScript table.
- **Type-name prefix** for project-owned types is `TLWPT`/`ELWPT`/`ILWPT`. Workspace-package types follow each package's own convention (HTTPClient uses `T...HTTPResponse` etc.; CLI uses `T...Option`; Semver uses `T...Semver`; etc.).

## OOP defaults

- **Classes are the modeling primitive.** Each domain concept gets its own class with explicit responsibilities. Reach for records, plain procedures, or generic data structures only when there is no behavior to attach.
- **Mark small subroutines `inline`** where it makes sense — trivial accessors, hot-path one-liners. The directive is a hint; FPC decides whether to actually inline. Skip on large bodies, recursive routines, and routines whose address is taken.
- **`const` parameters by default.** Use `var` or `out` only when the parameter is mutated. `const` applies to objects, strings, records, integers — anything not intentionally written.
- **No magic literals.** Bare numeric and string literals are extracted into named constants and declared in the `interface` section when shared between `interface` and `implementation`.
- **Generic specializations have named aliases.** When a generic specialization (`TObjectList<TFoo>`, `TOrderedMap<K,V>`, etc.) is used across more than one unit, declare a single named alias in the unit that owns the parameter type. Do not re-specialize the same generic locally — separate VMTs cause cross-unit type-cast failures under strict object checks.
- **RTTI via `TypInfo`** when introspection is needed. Expose the relevant properties and methods in `published`, and read/write them through `GetPropInfo` / `GetPropValue` / `SetPropValue`.

## File organization

- **`interface` declares only the public API.** Heavy or cycle-causing dependencies go in the `implementation uses` clause to break circular references. `LWPT.Core` exposes project identity, the error hierarchy, and low-level helpers; manifest, install, command, and formatter behavior live behind their owning units.
- **Constants live in `interface`** when they're public (e.g. `PROGRAM_NAME`, `MODULES_DIR`); in `implementation` when they're private to the unit.
- **Minimal public API.** Units expose only what's needed.

## Uses clauses

- **One unit per line.** Alphabetised within groups. Blank line between groups.
- **Group order:**
  1. System / RTL units (`SysUtils`, `Classes`, `zstream`, `Process`).
  2. Third-party / non-prefixed project units (`CLI.Options`, `HTTPClient`, `Semver`).
  3. Namespaced project units (`LWPT.Core`, `LWPT.Manifest`, `LWPT.Formatter`, `CLI.Subcommands`, `CLI.Prompts`).
  4. Relative-path units (rare in LWPT; reserve for future submodules).

`lwpt format` enforces all of this. Example after formatting:

```pascal
uses
  Classes,
  SysUtils,
  Process,

  CLI.Options,
  CLI.Subcommands,
  HTTPClient,

  LWPT.Core;
```

### The `Windows` unit shadows SysUtils

In any unit whose uses clause names `Windows` (always under
`{$IFDEF MSWINDOWS}`, and always in the implementation section — so it
resolves *after* the interface's `SysUtils`), Win32 declarations shadow
same-named SysUtils identifiers. The collisions that bite:

- `FindClose` — `Windows.FindClose(THandle)` shadows
  `SysUtils.FindClose(var TSearchRec)`. An unqualified call compiles fine
  on macOS/Linux and breaks only the win32/win64 builds — and the PR
  workflow builds on Linux only, so the break lands on `main` first.
- `DeleteFile` — `Windows.DeleteFile(PChar)` shadows
  `SysUtils.DeleteFile(string)`; same Windows-only failure mode.

**Rule:** in a `Windows`-using unit, qualify the whole
`SysUtils.FindFirst` / `SysUtils.FindNext` / `SysUtils.FindClose` family
and `SysUtils.DeleteFile`. FindFirst/FindNext have no Win32 collision,
but the family travels together so the pattern stays greppable and
consistent. Units without `Windows` in their uses clause are unaffected
and stay unqualified.

## Formatter contract

`lwpt format` enforces the rules above plus:

- Trailing whitespace stripped.
- Line endings normalised to LF.
- Uses-clause grouped, alphabetised within groups, blank line between groups.
- Identifier casing for declared types (auto-cased to declared form).

What the formatter does *not* do (today):

- Indentation normalisation. Pascal's free-form syntax makes this a much larger formatter project; deferred until there's evidence reviewers are bothered by indentation drift.
- Comment style enforcement. Reviewer's job.
- Line-length wrapping. Reviewer's job; 80-ish is conventional.

### Invocation

```sh
./build/lwpt format             # rewrite in place
./build/lwpt format --check     # exit non-zero on any deviation; do not write
```

`--check` is the form CI and the pre-commit hook use.

### Scope: include + exclude

The format scope is composed declaratively in the manifest. Full spec in [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md); the short version:

- **Seed**: `[package].units` (each dir, non-recursive, formattable extensions only).
- **Add**: `[format].include` — array of globs added on top of the seed.
- **Subtract**: `[format].exclude` — array of globs removed from the resolved set.

Formattable extensions: `.pas`, `.inc`, `.dpr`, `.lpr`.

```toml
[format]
include = [
  "tests/integration/*.pas",       # all .pas at tests/integration top level
  "tests/support/*.pas",
  "scripts/build-helper.pas",      # a literal file
  "src/legacy/**/*.{pas,inc}"      # NOT v1 — { } brace expansion is a future
                                    # add; today write two entries.
]
exclude = [
  "source/CLI.Parser.pas",         # opt-out example: a single file you don't want
                                   # the root formatter to rewrite
]
```

#### Glob syntax (v1)

| Pattern | Matches |
| --- | --- |
| `*` | any sequence of non-`/` characters |
| `**` | any sequence of characters including `/` (crosses dirs) |
| `?` | single non-`/` character |
| literal anything else | itself |

Plain dir names are shorthand for `<dir>/*.{pas,inc,dpr,lpr}` — **top-level only**. Recursion requires explicit `**`. `tests`, `tests/`, and `tests/*.{pas,inc,dpr,lpr}` all mean the same thing for the formatter (top-level `tests/` formattable files).

#### Behavior matrix

| Input | Behavior |
| --- | --- |
| Literal file path that exists, formattable extension | Added |
| Literal file path that exists, non-formattable extension | Filtered out silently |
| Literal dir path that exists | Expanded via plain-dir shorthand |
| Literal path that doesn't exist | Hard error (`EManifestError`) — literals assert presence |
| Glob with zero matches | Silent — globs validly resolve to nothing |
| Hidden file/dir reached via a wildcard segment (`*`, `**`, `?`) | Skipped (matches shell convention) |
| Hidden file/dir named explicitly by a dot-prefixed segment (`.lwpt/**`) | Matched — naming the dot opts in (shell convention; lets `exclude = [".lwpt/**"]` carve out `[package].units` entries that point into `.lwpt/`) |
| Case sensitivity | Case-sensitive everywhere |

#### Composition

Include defines the set; exclude subtracts. There's no precedence game beyond that: every file the include resolution produces is checked against the exclude resolution and removed if matched. Re-running `lwpt format` against an unchanged tree is a no-op (covered by `LWPT.Formatter.Test`'s idempotence suite).

Paths are resolved relative to the project root (where `lwpt.toml` lives). Absolute paths in `include` / `exclude` are not supported in v1.

When you add a new package under `packages/<name>/`, it's auto-discovered via `[workspaces] include = ["packages/*"]` and auto-formatted by the root's `[format].include = ["packages/**/*.pas", "packages/**/*.inc"]` (per ADR-0017's root-owns-unless-overridden model). If a specific package needs different formatting rules, declare a `[format]` section in `packages/<name>/lwpt.toml` to opt out. When you add a `source/`-resident file that genuinely shouldn't be formatted, add it to the root `[format].exclude` and note the reason inline.

## Comments

- Pascal block comments `{ ... }` do **not** nest by default in FPC mode `objfpc`. If a comment body contains literal `{` or `}` (e.g. quoting TOML or FPC include syntax), use `(* ... *)` for the outer.
- **No patch markers.** Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT-canonical code does not carry `{ [LWPT patch] }` / `{ [gpm patch] }` markers — git history is the canonical record of every change. Inline Pascal comments still document *why* non-obvious code looks the way it does (e.g. why HTTPClient uses a byte-safe `AppendRawBytes` instead of `Copy(PAnsiChar)`).
- Documentation comments should explain non-obvious intent, trade-offs, or constraints. **Do not narrate what the code does.** Don't write `{ Increment the counter }`. Do write `{ Skip the trailing CRLF — see RFC 7230 §3.5 }`.

## Magic numbers and strings

Extract into named constants in the `interface` section when shared. Examples in `LWPT.Core`:

- File and directory paths derived from `PROGRAM_NAME`.
- The `LWPT_DIR` / `MODULES_DIR` / `ARCHIVES_DIR` / `TMP_DIR` constants.
- The error-class hierarchy.
- SHA-256 round constants (the `K` array is large but conceptually a single named constant).

## Include files

- Shared compiler directives live in `Shared.inc`. Every unit that needs `{$mode delphi}`, `{$H+}`, `{$M+}`, etc. pulls the directives via `{$I Shared.inc}`. Do not repeat directives in each unit. The root project has `source/Shared.inc`; each workspace package has its own bundled copy under `packages/<name>/source/Shared.inc` for self-containment.
- All project-owned units + the renamed CLI / Semver units flow through `Shared.inc`. There used to be a `Goccia.inc` indirection for the `Goccia.*` namespace; with the prefix-strip (`Semver` is now plain `Semver`; `Goccia.Constants.NumericLimits` was inlined into it), nothing needed the indirection anymore and the file was removed.
- LWPT's own project-wide directives are declared inline in each unit (we use both `{$mode objfpc}` and `{$mode delphi}` depending on the file's lineage); no separate LWPT include file is needed today.
