# `lwpt run`, `[build]`, and the placeholder rename

The subcommand surface, frozen at seven since ADR-0010, expands to eight with `lwpt run` — a verb that invokes a user-declared script from the manifest (`lwpt run deploy` runs the `[deploy]` section's script) AND that aliases to any built-in subcommand when the name matches (`lwpt run install --frozen` ≡ `lwpt install --frozen`). The aliasing layer is in the CLI dispatcher, not in the run handler, so the per-subcommand option parsing is reused unchanged. In the same wave, the `[targets]` manifest section is renamed to `[build]` (`[targets].cli = { ... }` → `[build.cli] = { ... }`, equivalent to `[build] cli = { ... }`), with a single-entry shorthand that lets `[build] source = "..."` declare a one-binary project without naming the entry (it defaults to `[package].name`). The placeholder namespace ADR-0012 set up is renamed accordingly: `{target.*}` becomes `{item.*}` (the build-table noun that doesn't collide with a section name); `{build.os}` / `{build.arch}` become `{platform.os}` / `{platform.arch}` (so `{build.*}` is free to mean "the build item in scope" without colliding with host platform); `{name}` and `{version}` gain explicit `{package.name}` / `{package.version}` forms; the bare `{name}` becomes a context-sensitive resolution (entry's key inside `[build].<entry>`, falls back to `[package].name` outside). The unrecognised-section policy from ADR-0011 splits cleanly: a top-level section that's a table with a `script` field becomes a run-script; everything else keeps the existing one-line stderr warning. Reserved-name guard refuses sections whose names shadow LWPT subcommands (`[install] script = "..."` → hard error with a migration hint) so the `lwpt run <name>` lookup is never ambiguous between user scripts and built-in verbs.

## Considered Options

### Move `[targets]` into `[build]` (Q11)

- **Keep `[targets]`.** No change. Rejected — "target" is Bazel/Make vocabulary; LWPT users coming from npm/Cargo expect `[build]` or `[bin]`. Symmetric naming with `[prebuild]` / `[postbuild]` matters: hooks and their target sit in the same conceptual section.
- **`[targets]` → `[build.targets]`.** Adds an intermediate namespace level. Rejected — `[build]` itself would have nothing else to hold (build-wide config like default mode already lives in `--mode` flag / `[lwpt]` overrides); the intermediate `targets` level is dead weight.
- **`[targets]` → `[build]` (per-entry sub-section also valid via TOML sugar).** *Chosen.* TOML treats `[build.cli]` as sugar for `cli = { ... }` inside `[build]` — both forms produce the same `build.cli.source` access path. Projects pick whichever reads better: inline-table for short entries, sub-sections for entries with long per-entry hook configs.

### Single-target shorthand inside `[build]` (Q11b)

- **No shorthand.** Every project names its entry explicitly. Rejected — duplication for the common single-target case (`[package].name = "myapp"` + `[build.myapp].source = "..."` = the same name twice).
- **Section-name interpolation** — `[build.{package.name}]` as a templated section header. Rejected per the survey of TOML-based build systems (Cargo / pyproject / npm / Maven element-names all refuse it). Standard TOML parsers (taplo, IDE plugins) would choke; cycle detection becomes a real concern.
- **Single-entry shorthand: `[build]` with `source` directly.** *Chosen.* When `[build]` carries a `source` field at its top level (no nested keys), it's treated as one entry with `Name = [package].name` and `Output` defaulting to `build/<package-name>` if absent. Multi-entry projects use the explicit `[build.<entry>]` form unchanged. No parser surgery; no tool-compat cost.

### Placeholder namespace, all-flat vs all-dotted (Q11a' / Q11a)

- **All flat — `{name}`, `{source}`, `{output}`, `{os}`, `{arch}`.** Most concise; matches the `[sources]` URL-template style. Rejected — context-sensitive `{name}` shadowing across whole-build hooks (package) vs build-entry fields (entry) is an implicit-rule footgun. Reader of any single field-line can't tell which `{name}` they're getting.
- **All dotted — section-name namespaces (`{build.name}` for entry, `{host.os}` for platform).** Rejected — `{build.*}` for "the build item in scope" would collide with `{build.os}` / `{build.arch}` from the (pre-amendment) GocciaScript mirror. Resolving the collision via `{host.*}` for platform would silently break the Goccia access-path mirror established by ADR-0012.
- **All dotted — semantic namespaces (`{package.*}` / `{item.*}` / `{platform.*}`).** *Chosen.* No collision; every placeholder is self-documenting; no shadowing. `{item.*}` is the noun for "an entry in a table" (TOML doesn't have a perfect word; `item` reads more conversationally than `entry`). `{platform.os}` / `{platform.arch}` are the rename of `{build.os}` / `{build.arch}` that frees up `{build.*}` for nothing (`[build]` entries get `{item.*}` instead) — also clarifies that they're about the host platform LWPT is running on, not about anything related to the `[build]` section.

### Unrecognised-section policy revisited (Q12 / amended ADR-0011 §"[generated] migration")

- **Keep ADR-0011's warn-only policy.** Every unrecognised top-level section emits `warning: ... — ignored` to stderr and is dropped. Rejected — the original wave intended this to cover typos + legacy sections, but the policy is too broad: it discards perfectly-valid user data (`[deploy] script = "..."` is a clear intent that the warning hides).
- **Hard error on every unrecognised section.** Maximally strict. Rejected — projects use unrecognised sections for editor metadata (`[tool.editor]`-style conventions from Cargo), and the warning was specifically a softer alternative to hard-error to accommodate that.
- **Split: with-`script`-field becomes a run-script; without-`script`-field stays as warning.** *Chosen.* The two behaviours target different audiences: a section with `script` is an explicit user declaration of "I want to run this with `lwpt run X`"; a section without `script` is either a typo, dead config, or third-party metadata (and the warning helps catch typos without erroring on the metadata case). The split is detectable with a single TOML query (`is table` + `script` is string), so the implementation cost is one branch in the existing unknown-section loop.

### Shape of a run-script entry (Q12 entry shape)

- **Bare-string shorthand only** — `[deploy] = "scripts/deploy.pas"`. TOML doesn't allow it (sections are always tables, not scalars); listed for completeness.
- **Minimal — `script` + optional `args` only.** Rejected — drops staleness-gating that hook entries already support (`inputs` / `output` pair), forcing scripts to re-implement their own change detection.
- **Reuse the hook entry shape (`script` + optional `args` + paired `inputs`/`output`).** *Chosen.* A hook and a run-script are structurally the same thing — a script invoked with arguments, possibly gated on staleness. Forcing two slightly different schemas (one for hooks, one for scripts) doubles the parser surface, test surface, and docs surface for no gain. Reuse means `lwpt run regen-protos` with `inputs = ["**/*.proto"]` + `output = "src/proto.pas"` works the same way as a `[prebuild]` entry with those fields.

### `lwpt run <subcommand>` aliasing (Q12 aliasing)

- **Refuse aliasing — `lwpt run install` is an error ("no script named install").** Rejected per the user's explicit request — `lwpt run` should be a uniform front-end, not a separate channel that requires the user to remember which names go where.
- **Re-exec as a child process.** `lwpt run install --frozen` could literally `TProcess` re-spawn `lwpt install --frozen`. Rejected — extra process overhead, breaks signal handling + stdio inheritance edge cases, and forces the lwpt binary path to be discoverable.
- **In-process dispatch via the CLI registry.** *Chosen.* The subcommand dispatcher (`CLI.Subcommands.Run`) detects the alias before the run-handler runs, looks up the matched subcommand in the registry, and re-parses argv starting at position 3 (`argv[1]='run', argv[2]='<subcmd>', argv[3..] = subcmd args`). The existing per-subcommand option parsers (`--frozen`, `--mode`, etc.) work unchanged because `ParseCommandLine` now accepts a start-index parameter. No process spawn, no signal-handling subtlety, no special-case in any handler.

### Reserved-name guard (Q12 guard)

- **Allow any section name.** `[install] script = "..."` would be a valid run-script. Rejected — `lwpt run install` would then have two possible meanings (the user's script vs. the built-in subcommand), and the aliasing layer can't disambiguate without runtime context the dispatcher doesn't have.
- **Disallow at the registry level only — silent precedence.** Built-in always wins; user's `[install] script = "..."` is silently shadowed. Rejected — the user's section is present in their manifest but never callable; that's the kind of silent-no-op that breeds 2am bugs.
- **Hard error at manifest load.** *Chosen.* A section named `[install]` / `[build]` / etc. with a `script` field raises `EManifestError` naming the conflict + suggesting either renaming the section or invoking the built-in subcommand directly. The error message includes both the offending name and the safe pattern (e.g. `[install-deps]` instead of `[install]`).

## Consequences

- **Subcommand surface grows from 7 to 8.** `init`, `install`, `build`, `format`, `test`, `export`, `repair`, `run`. AGENTS.md's Hard Constraint about the frozen subcommand surface gains a third ADR-cited exception (after ADR-0010 for `init`). Future subcommand additions still require their own ADR.

- **`[build]` is the canonical name for build-item declarations.** Both shapes are accepted:

  ```toml
  # multi-entry, inline-table form
  [build]
  cli  = { source = "src/cli.pas",  output = "build/cli" }
  tool = { source = "src/tool.pas", output = "build/tool" }

  # multi-entry, sub-section form (TOML-equivalent)
  [build.cli]
  source = "src/cli.pas"
  output = "build/cli"

  # single-entry shorthand (entry name defaults to [package].name;
  # output defaults to "build/<name>" if absent)
  [build]
  source = "src/main.pas"
  ```

- **Single-entry shorthand defaults.** When `[build]` carries a `source` field directly, the entry's `Name` = `[package].name`, `Output` defaults to `"build/" + [package].name` if not declared. The shorthand still accepts `prebuild` / `postbuild` fields under `[build]` directly.

- **`[targets]` joins the unknown-section policy.** A manifest that still uses `[targets]` gets `warning: unrecognised section [targets] — ignored` + nothing builds. Migration is a one-line rename (`s/\[targets\]/\[build\]/`). The repo's own `lwpt.toml` migrated in the same PR.

- **Placeholder namespace, fully enumerated post-rename:**

  | Where | Available placeholders |
  | --- | --- |
  | `[build].<entry>.<field>` (any string field) | `{package.name}`, `{package.version}`, `{item.name}`, `{item.source}`, `{item.output}`, `{platform.os}`, `{platform.arch}` |
  | `[build].<entry>.{prebuild,postbuild}.<hook>.<field>` | same — per-item context |
  | `[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` `.<hook>.<field>` | `{package.name}`, `{package.version}`, `{platform.os}`, `{platform.arch}` only ({item.*} is a hard error — no item in scope) |
  | `[<script-name>].<field>` (run-scripts) | same as whole-build hooks |
  | `[sources].<name>.<field>` (URL templates — unchanged) | `{user}`, `{repository}`, `{ref}` (separate dialect, ADR-0009) |

- **Resolution order, updated:** pass 1 expands `[build].<entry>.source` / `[build].<entry>.output` with `{item.name}` bound but NOT `{item.source}` / `{item.output}` (those would be self-referential). Pass 2 expands per-entry hook fields with the full item context (`{item.source}` / `{item.output}` now resolved + bindable). Whole-build hooks + run-scripts run with `HasItemName=False` so `{item.*}` is a hard error there.

- **GocciaScript mirror is now value-only, not access-path.** Pre-ADR-0013, `Goccia.build.os` ↔ `{build.os}` in TOML — same path, same vocabulary. Post-ADR-0013, `Goccia.build.os` ↔ `{platform.os}` — same vocabulary (`darwin`/`linux`/etc), different access path. ADR-0012's "value + access-path mirror" softens to "value-only mirror"; `docs/vendored.md`'s `Platform.pas` row gains a one-line note. The vendored unit name stays `Platform.pas` (it always did — the unit doesn't import the access-path semantics, just the value table).

- **Run-script section shape** mirrors hooks exactly:

  ```toml
  [deploy]
  script = "scripts/deploy.pas"
  args   = ["{package.name}", "--env", "{platform.os}"]

  [regen-protos]
  script = "scripts/protoc-wrapper.pas"
  inputs = ["**/*.proto"]
  output = "source/protos.Generated.pas"
  ```

  The bare-string shorthand `[deploy] = "..."` isn't a thing because TOML section values are always tables. The closest is `[deploy] script = "..."` (single-key inline form).

- **Reserved-name guard** runs at manifest load. The eight protected names are `install`, `build`, `format`, `test`, `export`, `repair`, `init`, `run`. A section with any of these names + a `script` field raises:

  ```text
  section [install] shadows the built-in subcommand and cannot be used
  as a run-script. Rename the section (e.g. [install-task]) or invoke the
  subcommand directly (`lwpt install`). See ADR-0013.
  ```

- **`lwpt run` (no script name) lists callable names** — registered subcommands first, then user scripts. Matches npm's `npm run` no-args convention. Output goes to stdout (it's an informational view, not a warning).

- **`lwpt run <subcommand-name> [args...]` aliases in the CLI dispatcher.** The handler never sees this case — the dispatcher detects the alias before parsing, then calls the matched subcommand's handler with argv parsed from position 3 onward. `ParseCommandLine` (in `CLI.Parser`) gained an `AStartArg` parameter (default 1) to support this; existing callers are unchanged.

- **Supply-chain stance is preserved.** Run-scripts, like hooks, are root-only. A dep manifest's `[deploy] script = "..."` is silently dropped by the loader (`AIsRoot=False`). The "any unrecognised section becomes a script" surface doesn't widen the supply-chain attack vector — dep manifests still can't add anything callable to a consumer's `lwpt run` surface.

- **Two ADRs are amended** by this work:
  - **ADR-0011 §"[generated] migration" (Q10)** — the unknown-section policy is now "if it's a script section, register it; otherwise warn-and-drop". The `[generated]` case + `[teddybear]` case both still fall into warn-and-drop (neither has a `script` field).
  - **ADR-0012 §"Build-context names + values"** — the placeholder names rename per the namespace table above; the GocciaScript mirror softens from "value + access-path" to "value-only".

- **The decision forecloses** placeholder section-name interpolation (`[build.{package.name}]` etc.), arbitrary unrecognised sections being treated as anything other than scripts-or-warnings, and dependency-declared scripts. All three remain reversible via a future ADR but each has a sharp UX/safety reason to stay closed.

- **The decision opens** future `[build.<entry>]`-level fields beyond `source` / `output` / hooks (compiler flags overrides, conditional `os = "darwin"` filters, etc) without naming-conflict surprises — the namespace is empty above the field level.
