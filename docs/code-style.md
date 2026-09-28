# Code style

Naming, file layout, formatter rules, manifest scope with protected toolkit state, line-ending normalisation. The conventions inherited from `native-nostalgia-stack` plus the LWPT-specific additions that crystallised over the spike-to-production work.

## Executive Summary

- **Identifiers are PascalCase, no underscores, no abbreviations.** Industry-standard acronyms (HTTP, JSON, UUID, **LWPT**) stay as-is. Type prefix `T`, exception `E`, interface `I`, private field `F`, parameter `A` (when ≥ 2 letters).
- **The project name lives in two constants.** `PROGRAM_NAME = 'lwpt'` (lowercase Unix convention; derives filenames and shell commands) and `PROJECT_NAME = 'LWPT'` (uppercase acronym in prose). See [ADR-0001](./adr/0001-program-name-as-constant.md). Never hardcode either spelling.
- **LWPT-internal units use the dotted `LWPT.<Subsys>.pas` form.** Workspace packages under `packages/<name>/source/` follow their own naming and public-surface contracts (see [`packages.md`](./packages.md)). Root formatting applies across workspace packages by default; a package opts out by declaring its own `[format]` section.
- **`lwpt format` is the canonical formatter.** No-flag invocation rewrites in place and is used by pre-commit; `--check` is the non-mutating CI form. Rules are encoded in the Pascal source of `LWPT.Formatter`, not in a config file.
- **Formatter scope is manifest-declared with one safety boundary**: `[package].units` + `[format].include`, root `.lwpt/**` excluded unless explicitly included, then `[format].exclude`. Globs are supported; recursion is explicit via `**`. See [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md) and [ADR-0028](./adr/0028-default-toolkit-state-format-exclusion.md). Root LWPT's `[format].include` covers `tests/integration/`, `tests/support/`, `tests/e2e/`, and every workspace package (`packages/**/*.{pas,inc}`) so the canonical style applies across the monorepo. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md)'s root-owns-unless-overridden model, a workspace package can opt out by declaring its own `[format]` section in `packages/<name>/lwpt.toml`.
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
  on macOS/Linux and breaks only the win32/win64 builds. The PR workflow's
  Windows cross-compile and native-test jobs catch this before merge.
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

**Comments, compiler directives, and string literals are never rewritten.** Every pass reads the file through the same mode-aware tokenizer as `lwpt health` and `lwpt duplication`, and rewrites whole code tokens only. Prose inside `{ … }`, `(* … *)`, or `//` that happens to begin with `function`, `procedure`, or `uses` is left alone, and a rename never touches a comment, directive, or string that mentions the old name. Comment nesting follows the file's own `{$mode}` and `{$modeswitch nestedcomments}` directives; with neither, comments nest as in FPC's default mode. A mode chosen only on the command line or in an include file is not seen, and a mode directive counts wherever it appears, even inside a conditional branch the build does not take. A file that is not lexically valid (an unterminated comment, or a string whose closing quote is not on its line) is left untouched. The formatter applies that string rule even inside a conditional branch the build does not take, where FPC tolerates such text. `lwpt health` and `lwpt duplication` keep reading those strings on to their closing quote. `lwpt format` names it and the reason. `lwpt format --check` counts it as a file it could not check and exits non-zero, because it cannot vouch for the file's formatting. An InstantFPC script's leading `#!` line is skipped.

**Parameter renames are scoped, and skipped when the binding is uncertain.** A parameter's `A`-prefix rename covers every header of its routine in the file and the body each header owns: FPC rejects an implementation whose parameter names differ from its declaration. Headers belong to one routine when they share the qualified name, the enclosing routine, and each parameter's modifier and type, so overloads and same-named nested routines are decided separately. The body is found even when `begin` shares the header's line. It includes every branch when alternative bodies sit in a conditional block with nothing else between them. A header without a body keeps the rename in the header: a class or record member, a `forward` or `abstract` declaration (whose directive may be on a later line), or an interface-section declaration.

A nested routine that binds the name itself, as a parameter, variable, constant or type, keeps its own binding. A record or class field of the same name is not the parameter and keeps its name. An `absolute` alias of the parameter in the routine that owns it is renamed with it. A member access (`Entry.ACount`) is never a collision. Only identifier tokens are renamed, never keyword tokens: an escaped `&begin` becomes `ABegin` while the `begin` keywords around it stay. The formatter leaves a parameter as it is when:

- a header of its routine is `external` (renaming external parameters is out of scope);
- the parameter is spelled like a directive word the tokenizer reads as a keyword (`message`, `name`, `index`);
- the routine contains assembler, whose operands cannot be told from registers, or an include directive, whose text the formatter cannot see;
- the routine's conditional directives do not balance, its headers are alternatives in conditional branches, or a conditional or include directive sits inside a parameter list;
- the name is used in a header other than as a parameter (a type of the same name), or in the routine's own declaration part other than as a field or an `absolute` target (an initializer label, for example);
- a nested routine uses the name in its declarations other than as a binding or a field (an initializer such as a typed constant's `(count: 7)`, or an `absolute` target), or a nested routine has the name;
- the parameter has its routine's name;
- a `with` statement precedes a use of the name, since the name may then be a member of the `with` subject;
- the new name is already used, unqualified, where the parameter would be visible;
- an implementation omits the parameter list its declaration gives, or declarations and implementations of one name cannot be paired by signature;
- another header spells the parameter with its prefix already (`aValue` against `AValue`).

The rename is decided per file. A routine declared in one file and implemented in another (through an include file) is only kept in step when both files reach the same decision.

Two known limits err on the side of leaving a parameter as it is:

- The qualified name keeps only the last type: `TFirst.TInner.Show` and `TSecond.TInner.Show` group together, so a reason to skip one skips both.
- A field of the new name in a record or class declared in the routine counts as a collision, although a field cannot be reached unqualified.

Parameter renaming is heuristic and token-based; a move to syntax-tree-based renaming is tracked separately.

**A uses clause that carries a compiler directive or a comment is left exactly as written.** Reordering across `{$IFDEF}` would change which units a build sees, and a comment inside a uses clause exists to pin a position — see the `cthreads, { must come first so TThread has a driver }` clauses in the test programs. The formatter therefore treats any clause containing `{$…}`, `//`, `{ … }`, or `(* … *)` as author-owned and emits it verbatim; grouping and alphabetisation are on you in those clauses. A clause that no semicolon closes before the next declaration or the end of the file, or that has more code after its semicolon on the same line, is also emitted as written, as is one whose unit entry spans lines. Entries are split at comma tokens, so a comma inside an `in 'path'` string stays in its entry. Sorting can change which unit a name resolves to when two units declare it; such a clause needs a comment to pin its order. Everything else the formatter does (trailing whitespace, line endings, identifier casing) still applies to the rest of the file.

What the formatter does *not* do (today):

- Indentation normalisation. Pascal's free-form syntax makes this a much larger formatter project; deferred until there's evidence reviewers are bothered by indentation drift.
- Comment style enforcement. Reviewer's job.
- Line-length wrapping. Reviewer's job; 80-ish is conventional.

### Invocation

```sh
./build/lwpt format             # rewrite in place
./build/lwpt format --check     # exit non-zero on any deviation or unreadable file; do not write
```

`--check` is the form CI uses; pre-commit runs the rewriting form and stages
the formatter's fixes.

### Scope: include + exclude

The format scope is composed from the manifest plus the toolkit-state safety boundary. Full spec in [ADR-0007](./adr/0007-formatter-scope-manifest-declared.md) and [ADR-0028](./adr/0028-default-toolkit-state-format-exclusion.md); the short version:

- **Seed**: `[package].units` (each dir, non-recursive, formattable extensions only).
- **Add**: `[format].include` — array of globs added on top of the seed.
- **Protect**: toolkit state — root `.lwpt/**`, any `[lwpt]` `modules-dir` / `archives-dir` / `tmp-dir` / `cfg-file` override paths, and the project-owned `p-<hash>` namespace below a `sessions-dir` override (not the shared base itself) — excluded unless a matching explicit include added the file.
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
| Hidden file/dir named explicitly by a dot-prefixed segment (`.cache/**`) | Matched — naming the dot opts in under the shell convention |
| File under root `.lwpt/**` contributed only by `[package].units` | Excluded by default to protect committed toolkit state |
| File under root `.lwpt/**` matched by `[format].include` | Added explicitly; the default exclusion is overridden |
| Case sensitivity | Case-sensitive everywhere |

#### Composition

The units seed and includes define the candidate set. Files under root `.lwpt/**` then leave the set unless an explicit include matched them. Explicit excludes subtract last and therefore still remove a file that was also explicitly included. Re-running `lwpt format` against an unchanged tree is a no-op (covered by `LWPT.Formatter.Test`'s idempotence suite).

Paths are resolved relative to the project root (where `lwpt.toml` lives). Absolute paths in `include` / `exclude` are not supported in v1.

When you add a new package under `packages/<name>/`, it's auto-discovered via `[workspaces] include = ["packages/*"]` and auto-formatted by the root's `[format].include = ["packages/**/*.pas", "packages/**/*.inc"]` (per ADR-0017's root-owns-unless-overridden model). If a specific package needs different formatting rules, declare a `[format]` section in `packages/<name>/lwpt.toml` to opt out. When you add a `source/`-resident file that genuinely shouldn't be formatted, add it to the root `[format].exclude` and note the reason inline.

## Comments

- Whether Pascal block comments nest depends on the mode. They nest in FPC's default `fpc` mode and in `objfpc`, and `{$modeswitch nestedcomments+}` turns nesting on elsewhere. They do not nest in the `delphi` mode that `Shared.inc` selects. If a comment body contains literal `{` or `}` (e.g. quoting TOML or FPC include syntax), use `(* ... *)` for the outer so the comment reads the same in every mode.
- **No patch markers.** Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), LWPT-canonical code does not carry `{ [LWPT patch] }` / `{ [gpm patch] }` markers — git history is the canonical record of every change. Inline Pascal comments still document *why* non-obvious code looks the way it does (e.g. why HTTPClient uses a byte-safe `AppendRawBytes` instead of `Copy(PAnsiChar)`).
- Documentation comments should explain non-obvious intent, trade-offs, or constraints. **Do not narrate what the code does.** Don't write `{ Increment the counter }`. Do write `{ Skip the trailing CRLF — see RFC 7230 §3.5 }`.

## FPC and libc interop

Three idioms, each minted by a real defect (PR #105):

- **After a libc external fails, read errno via libc's accessor**
  (`__errno_location` on Linux, `__error` elsewhere), never `FpGetErrNo`.
  On Linux the RTL keeps its own errno threadvar for its raw-syscall
  wrappers; reading it after a libc call returns a stale, unrelated code.
  See `CErrnoLocation` in `LWPT.ProcessTree`.
- **Process-environment sweeps go through `LWPT.Core.AppendProcessEnvironment`**,
  never a raw `1..GetEnvironmentVariableCount` loop. The RTL lazily
  initialises its count global without synchronisation, so concurrent
  sweeps can read a partial count and silently truncate a child's
  environment.
- **Cross-thread flags are `LongInt` + `Interlocked*`**, never a bare
  `Boolean` — see `TLWPTProcessTree.FImmediateTerminationRequested` for
  the canonical shape.

## Magic numbers and strings

Extract into named constants in the `interface` section when shared. Examples in `LWPT.Core`:

- File and directory paths derived from `PROGRAM_NAME`.
- The `LWPT_DIR` / `MODULES_DIR` / `ARCHIVES_DIR` / `TMP_DIR` constants.
- The error-class hierarchy.
- SHA-256 round constants (the `K` array is large but conceptually a single named constant).

## Include files

- Shared compiler directives live in `Shared.inc`. Every unit that needs `{$mode delphi}`, `{$H+}`, `{$M+}`, etc. pulls the directives via `{$I Shared.inc}`. Do not repeat directives in each unit. The root project has `source/Shared.inc`; each workspace package has its own bundled copy under `packages/<name>/source/Shared.inc` for self-containment.
- All project-owned units + the renamed CLI / Semver units flow through `Shared.inc`. There used to be a `Goccia.inc` indirection for the `Goccia.*` namespace; with the prefix-strip (`Semver` is now plain `Semver`; `Goccia.Constants.NumericLimits` was inlined into it), nothing needed the indirection anymore and the file was removed.
