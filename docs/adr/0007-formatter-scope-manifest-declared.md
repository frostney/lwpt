# Formatter scope is manifest-declared, not convention-based

`lwpt format` operates on a "format scope" — the set of source files it processes. The scope is composed declaratively in the manifest: the seed is `[package].units`, additions come from `[format].include`, and subtractions come from `[format].exclude`. Both `include` and `exclude` are arrays of globs (`*` matches one path segment; `**` matches any depth — recursion is explicit; `?` matches one non-`/` character). Plain dir names are shorthand for `<dir>/*.{pas,inc,dpr,lpr}` (top-level only). The walk is non-recursive everywhere by default — including the `[package].units` seed, which matches FPC's `-Fu` semantics. We chose this over a convention-based default that hardcoded a `tests/` walk into the formatter (an earlier state, never committed) because conventions baked into the tool punish every project that doesn't follow them, and the manifest is supposed to be the single source of truth for what a project declares (ADR-0002 spirit).

## Considered Options

- **Convention-based: walk `[package].units` + hardcoded `tests/` if it exists** (an earlier implementation, never committed). Made LWPT's own setup work without manifest changes, but baked one specific test-layout convention into a tool that's supposed to be project-agnostic. Projects with `test/`, `spec/`, monorepo multi-roots, or in-source `*_test.pas` would either misformat or have no recourse.
- **`[format].dirs` (replace, not additive)**. Fully declarative but requires every project to re-list its `[package].units` dirs in `[format].dirs`, creating a drift hazard where the two arrays disagree. Additive composition avoids that by making `[package].units` always part of the seed.
- **`[format].include` as files only, separate `[format].include-dirs` for dirs**. More explicit but verbose; the glob system already disambiguates files vs dirs by FS check, so one array suffices.
- **Recursive by default, `**` redundant**. Matches the earlier behavior. Rejected because it diverges from FPC's `-Fu` semantics for `[package].units` and from shell glob conventions for `[format].include`.
- **Brace expansion `{a,b}` and character classes `[abc]` in v1**. Defer until a real use case appears; both expand the spec surface without immediate benefit.

## Consequences

- **`[package].units` recursion is a behavior change** from the spike's `CollectSourceFiles` (which recursed). Projects with nested package source need to add `[format].include = ["src/**/*.pas"]`. For LWPT itself, `source/` is flat — no change needed.
- **The shorthand `tests` resolves to `tests/*.{pas,inc,dpr,lpr}`**, not `tests/*.pas`. The shorthand is *defined* to mean "the formattable contents of this dir." Projects that want `.pas`-only can write the explicit glob.
- **Missing literal paths hard-error; missing glob matches are silent.** A literal asserts presence; a glob asserts a pattern.
- **Hidden files are skipped** by `*` (matches shell convention). A project that wants `.hidden.pas` formatted writes the literal path.

  *Amendment (2026-06):* a pattern **segment that itself starts with `.`** names the hidden entry explicitly and matches it — `.lwpt/**` enters `.lwpt/`, while `*` and `**` continue to skip hidden entries. This completes the shell-convention analogy (`ls .lwpt/*` works; `ls *` hides dotfiles) and closes a composition gap: `[package].units` entries may point into `.lwpt/` (vendored module sources compiled directly), and before the amendment no `[format].exclude` glob could subtract those seeded files because the walker refused to enter the hidden dir the glob explicitly named.
- **Case-sensitive matching everywhere**, including on macOS APFS (which is case-insensitive at the FS level by default). A project on case-insensitive FS still gets exact-match behavior the same way.
- The decision **forecloses** the convention-based shape; reverting requires re-adding hardcoded logic, which the manifest-as-source-of-truth principle would re-litigate. The decision **opens** glob-based scope to other LWPT subcommands later (test discovery, codebase-health, etc.) if a real need emerges — the glob helper is reusable.
