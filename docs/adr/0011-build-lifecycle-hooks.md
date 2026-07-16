# Build-lifecycle hooks supersede `[generated]`

LWPT gains a hook surface across three subcommands — `install`, `build`, `test` — with six top-level manifest sections (`[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]`) plus per-target `prebuild` / `postbuild` fields on `[targets].<name>` inline tables. Each hook entry is an InstantFPC script with optional `args` and an optional `inputs` / `output` pair that turns it into a staleness-gated rule (no re-run when output is fresher than every input). The bare-string shorthand `"scripts/foo.pas"` is equivalent to the full inline table `{ script = "scripts/foo.pas" }` — mirroring the `[dependencies]` syntax. Hooks fire **only** from the root manifest; dep manifests' hook sections are silently dropped by the loader (the npm-`postinstall` supply-chain hole closed by design). The old `[generated]` section, which solved a narrow sub-case of "prebuild with staleness check", is removed — its single in-repo entry migrates to a `[prebuild]` entry — and any manifest still using `[generated]` falls under the generic unknown-section policy (warning to stderr, silently dropped, identical treatment to `[teddybear]`). The whole design is a deliberate narrowing of npm's lifecycle-script model: same syntactic ergonomics, smaller surface (three subcommands, not nine), and a hard supply-chain stance baked in from day one.

## Considered Options

### Lifecycle attachment shape (Q1)

- **Whole-build only.** Top-level `[prebuild]` / `[postbuild]` arrays running once around the whole `lwpt build` invocation. Rejected because it can't express per-target work (sign one target, package another, skip the third) without the user inventing target-discriminating logic inside the hook script. Simple but expressive-floor too low.
- **Per-target only.** `prebuild` / `postbuild` fields inside each `[targets].<name>` entry. Rejected because shared prebuild work — like the existing `LWPT.Embedded.TestingLibrary.inc` regen that every test target depends on indirectly — would have to be either duplicated across every target or pushed into one "canonical" target with implicit ordering. Both bad.
- **Both whole-build and per-target.** *Chosen.* Whole-build for shared prep work that benefits every target; per-target for actions specific to one binary (sign, strip, package). The two surfaces compose cleanly: whole-build prebuild → for each target, per-target prebuild → fpc → per-target postbuild → whole-build postbuild against staged outputs → publish each successful output.
- **Richer npm-style lifecycle (pre/post for every subcommand).** Rejected as Q4 below.

### Entry shape (Q2)

- **Bare string commands** (`prebuild = ["scripts/embed.pas"]`). Rejected because it suggests shell parsing (which we don't want; no portable shell across Unix/Windows) and forecloses the structured fields (`args`, `inputs`/`output`) we need almost immediately.
- **Inline table only, always-run** (`prebuild = [{ script = "..." }]`). Rejected because every hook running every build sheds the only working feature we have today (the `[generated]` staleness check that lets edits to the testing library not blow away unrelated builds).
- **Inline table with optional staleness, bare-string shorthand allowed.** *Chosen.* Top-level sections are dep-syntax-style named-key tables — `embed-testing-library = { script = "..." }` or `embed-testing-library = "scripts/embed.pas"` — with the key serving as the human-readable hook name (used in log lines). Per-target hook fields are inline tables continuing the target's own inline table, same key-to-entry shape. `inputs` + `output` are an optional paired field for staleness gating; declaring only one is a manifest-load error.
- **Two separate concepts (`[generated]` for declarative + `[hooks]` for imperative).** Rejected — it's the shape we have today, and "feels a bit off" was the original complaint that opened this design discussion. Folding everything into one model with optional staleness gives one mental model for one concept.

### Subcommand scope (Q4)

- **Compilation subcommands only — `build` + `test`.** Smallest scope. Rejected because `install` is the third real lifecycle phase where projects have prep-and-cleanup needs LWPT doesn't model (asset fetch, devtool setup, env validation) — covering only 2 of 3 high-traffic verbs to save manifest surface is the wrong trade.
- **All seven subcommands** (also `format`, `export`, `repair`, `init`). Rejected because each of those four has *no* legitimate hook use case — see Consequences below for the per-subcommand refusal text. A complete surface that's 4/9 dead weight is worse than a deliberately narrow one.
- **`install` + `build` + `test`, others denylisted with documented rationale.** *Chosen.* The three subcommands users actually want hooks around; the other four explicitly DO NOT get hooks, with the reasoning embedded in this ADR so future "can we add `[preformat]`?" requests have a documented refusal to push back against.

### Supply-chain posture (Q5)

- **npm default — dep hooks auto-fire on install.** Rejected as the well-known attack vector (event-stream 2018, ua-parser-js 2021, node-ipc 2022, the entire typosquat-postinstall ecosystem). Not even listed as a serious option.
- **Root + opt-in allow-list.** `[hooks] allow-from = [...]` enumerates which deps' hooks can run. Rejected because an allow-list pinned by name (not by content) accepts any future hook the listed dep ships — a v3.0.0 → v3.0.1 update through the same name silently changes what runs. Content-hashing the allowed hooks IS the consent-prompt option below in disguise.
- **Root + one-time consent prompt.** Y/n on first encounter, consent recorded in the lockfile, `--frozen` refuses if the dep's hook changed since consent. Rejected because consent prompts during install are the worst UX anti-pattern — users muscle-memory through them in 99% of cases, and the 1% they should refuse, they won't. Every "do you trust this?" prompt ever shipped has this failure mode.
- **Root manifest only; dep hook sections silently dropped.** *Chosen.* Dep manifests' `[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]` sections are parsed-and-dropped by the loader when reading a dep's `lwpt.toml`. The resolver still reads `[package]` + `[dependencies]` + `[sources]` from dep manifests (it needs those to walk the graph). Audit visibility for what runs on install is "read the project's own `lwpt.toml`" — that's it. The whole supply-chain story collapses to one line: *we don't run anything dependencies ask us to.*

### Execution model + supported fields (Q6)

- **Direct-command invocation** (`{ command = "protoc", args = [...] }` runs the named executable). Rejected for cross-platform noise (`.bat` vs `.sh`, PATH resolution, quoting). Wrap external tools in a Pascal script via `TProcess` if you need them — the script is auditable, version-controlled, and platform-agnostic at the boundary you're crossing.
- **InstantFPC + `args` + `env` + `cwd` + everything.** Rejected as design-speculation; the default (project root cwd, inherited env) handles every use case in the codebase today and is non-breaking to extend later.
- **InstantFPC + `script` + `args` + paired `inputs`/`output`.** *Chosen.* Minimal schema that covers the existing `[generated]` use case (staleness-gated regen), the per-target sign/package use case, and the one-shared-script-per-target case (via `args` interpolation — see ADR-0012). Default invocation: `instantfpc <script> [args...]`, cwd = project root, env = inherited, stdout + stderr passthrough.

### `[generated]` migration (Q10)

- **Hard error with named migration text.** Originally chosen; reverted in favour of generalising the policy.
- **Silent translation** (auto-rewrite `[generated]` to `[prebuild]` at load). Rejected for two-vocabulary-forever code, plus the dep-manifest implication that we'd be re-firing dep `[generated]` sections under the new name.
- **Deprecation warning** (works like silent translation, prints "use `[prebuild]` instead"). Rejected for the same dual-vocabulary code-path cost without the policy clarity payback.
- **Permanent alias.** Rejected as silent translation forever.
- **Treat as any other unknown top-level section.** *Chosen.* LoadManifest carries a known-sections allowlist (`[package]`, `[dependencies]`, `[sources]`, `[build]`, `[format]`, `[lwpt]`, `[version]`, plus the six new `[pre*]` / `[post*]` sections). Anything else falls into one of two policies depending on the section's content:
  - **Section is a table with a `script` field** → registered as a user-callable run-script under ADR-0013. `[deploy] script = "scripts/deploy.pas"` becomes invokable via `lwpt run deploy`. Reserved-name guard: sections whose name shadows a registered subcommand (`install`, `build`, `format`, `test`, `export`, `repair`, `init`, `run`) raise `EManifestError` at load.
  - **Anything else** (table without `script`, scalar value, etc) → single `warning: unrecognised section [name] — ignored` to stderr and silently dropped. The legacy `[generated]` and `[targets]` cases both fall here (neither has a `script` field). `[teddybear]` falls here. Typos like `[depndencies]` fall here.

  No special-cased migration text inside the loader for any specific removed section; the rewrite recipes live in their respective ADRs (this one for `[generated]`, ADR-0013 for `[targets]`) and in the changelog. Migration is a search-and-replace on the project author's side, not a runtime conversation.

## Consequences

- **The hook surface is six top-level sections + two per-target fields.** Top-level: `[preinstall]`, `[postinstall]`, `[prebuild]`, `[postbuild]`, `[pretest]`, `[posttest]`. Per-target on each `[targets].<name>` inline table: `prebuild`, `postbuild`. Per-target fires only from `lwpt build` (targets exist only there).

- **Hook entry schema** (full + shorthand):

  ```toml
  # full inline table
  embed-testing-library = { script = "scripts/embed.pas",
                            args   = ["--mode", "release"],
                            inputs = ["source/TestingPascalLibrary.pas", "source/Shared.inc"],
                            output = "source/LWPT.Embedded.TestingLibrary.inc" }

  # shorthand (only `script`)
  embed-testing-library = "scripts/embed.pas"
  ```

  `inputs` + `output` are a paired option: both present (staleness-gated) or both absent (always-run); declaring exactly one is a manifest-load error. The key (`embed-testing-library`) is the human-readable hook name used in log lines.

- **Hook keys are TOML bare keys** — `[a-zA-Z][a-zA-Z0-9_-]*`. Same rule as dep names. Hyphens are encouraged for multi-word names because hook keys never become Pascal identifiers (unlike target entry names, which do).

- **Execution semantics, baked-in defaults:** sequential, manifest insertion order (preserved through TOML → `OrderedStringMap`), stop on first non-zero exit, project root as cwd, parent process's env inherited, stdout + stderr passthrough. Failure aborts the phase; later hooks in the same section don't run; the lifecycle phase exits with the failed hook's exit code (or 1 if a script raised). No parallelism — predictability over speed for a few-script lifecycle.

- **Subcommands that DO NOT get hooks, with documented refusals:**
  - **`format`** — running prebuild on every reformat defeats the lightweight "I just want to reformat" path; `[preformat]` as its own pair is duplicate plumbing for an operation that has no genuine pre/post need. Formatters are content transforms, not lifecycle phases.
  - **`repair`** — a recovery operation. Hooks could prevent recovery from a broken state (the hook depends on the broken state being repaired first; circular).
  - **`init`** — runs in an empty/near-empty dir. There's nothing for a hook to operate on yet; ADR-0010 already handles the "do you want install+build after init?" prompt for the start-of-life path.

  These refusals are listed here so future "can we add `[preformat]`?" requests have a documented reasoning to push back against. They're decisions, not omissions.

  earlier the denylist also included **`export`** — a one-shot extrude-the-embedded-testing-library operation that pre-dated the workspace-package model. [ADR-0015](./0015-drop-export-testing-becomes-workspace-package.md) removed both the subcommand and its denylist entry. The remaining three (`format`, `repair`, `init`) keep their original rationale.

- **Supply-chain stance is the strongest reasonable default.** Root manifest only. Dep manifests' hook sections are silently dropped. A consumer running `lwpt install` against a project with N transitive dependencies runs *only* whatever's listed in the root project's `lwpt.toml`. "What runs on install?" is answerable with `cat lwpt.toml | sed -n '/^\[\(pre\|post\)install\]/,/^\[/p'`. No transitive surprise, no consent-prompt UX, no allow-list drift.

- **Drop-silent for dep manifests; warn-or-register for root manifest unknown sections.** A dep manifest with `[teddybear]` or `[preinstall]` or `[deploy] script = "..."` produces zero output during graph traversal. The same root manifest entries either register as a run-script (when `script` is present — see ADR-0013) or produce `warning: unrecognised section [name] — ignored` to stderr (otherwise). Different audiences: root-manifest behaviour helps the *user* see typos and use declared scripts; dep-manifest sections would be either supply-chain attack vectors (scripts) or CI noise the user can't fix (warnings).

- **`[generated]` removal does not get special handling.** It joins the unknown-section policy. Migration recipe (recorded here, not in the loader's error message):

  ```toml
  # before
  [generated]
  "source/Foo.inc" = { generator = "scripts/bar.pas",
                       inputs    = ["a.pas", "b.pas"] }

  # after
  [prebuild]
  build-foo = { script = "scripts/bar.pas",
                inputs = ["a.pas", "b.pas"],
                output = "source/Foo.inc" }
  ```

  The old keyed-by-output-path shape becomes a hook with a chosen name (`build-foo` here) and explicit `output`. *Historical:* the pre-existing repo entry — `LWPT.Embedded.TestingLibrary.inc` — migrated to this shape in the same PR that landed this ADR, and was deleted entirely in a later cycle when ADR-0015 retired the embedded-blob model.

- **Hooks fire `install` first, `build` second, `test` third when the subcommands run.** Per-subcommand ordering:
  - `lwpt install`: `[preinstall]` → resolve + fetch + write lockfile + write cfg → `[postinstall]`
  - `lwpt build`: `[prebuild]` → for each target: per-target `prebuild` → fpc → per-target `postbuild` → `[postbuild]` against all staged outputs → publish all selected outputs
  - `lwpt test`: `[pretest]` → discover + compile + run each `*.Test.pas` → `[posttest]`

  Whole-build hooks fire once per `lwpt <verb>` invocation, regardless of how many targets / tests / packages are involved.

- **The cross-phase staleness pattern: declare in BOTH `[prebuild]` and `[pretest]`.** Strict subcommand-keyed semantics (the Q3 decision) means `[prebuild]` does not auto-fire from `lwpt test`, so a generator that needs to be fresh for both `lwpt build` AND `lwpt test` gets declared in both sections. The staleness gate (`inputs` + `output` newer-than check) ensures the script runs *at most once* per source edit regardless of how many sections list it; explicit declaration of "this script fires for these phases" beats implicit cross-phase firing for predictability + audit. *Historical note:* the original carrier of this pattern was the `LWPT.Embedded.TestingLibrary.inc` regen hook in LWPT's own root manifest — the pre-v1 testing-library staleness bug (edit `TestingPascalLibrary.pas`, run `lwpt test`, see stale `.inc`) was the motivating example for the dual-declare semantics. [ADR-0015](./0015-drop-export-testing-becomes-workspace-package.md) removed the embedded-blob model + the regen hook itself; the cross-phase declaration semantics survive for any future generator the pattern fits.

- **The decision forecloses three things:** parallel hook execution (we've baked sequential into the semantics; reverting would re-trigger every "but ordering!" discussion); shell-command invocation (everything's InstantFPC; arbitrary `command = "..."` would need its own ADR); and dependency-declared hooks (`(d)` from Q5 is now structurally impossible without a deliberate ADR-cited reversal).

- **The decision opens two things:** extending the schema (additional optional fields — `env`, `cwd`, `continueOnError`, etc — are non-breaking additions) and graduating `Platform.pas` + the hook implementation as standalone packages post-v1 alongside the rest of the graduation roadmap (ADR-0003).
