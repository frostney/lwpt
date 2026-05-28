# Manifest placeholder interpolation in `[build]` and hook fields

> **Amended by [ADR-0013](./0013-run-subcommand-and-build-rename.md)** — the placeholder namespace below is the post-ADR-0013 shape. The section originally targeted `[targets]` (renamed to `[build]`) and used `{target.*}` / `{build.os}` / `{build.arch}` placeholders (renamed to `{item.*}` / `{platform.os}` / `{platform.arch}`). The GocciaScript mirror is now value-only (vocabulary stays identical; access path diverges — `Goccia.build.os` in JS ↔ `{platform.os}` in TOML).

LWPT manifest string values in `[build].<entry>.<field>`, in every top-level hook section field (`[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]`), in per-entry hook fields, and in user run-script fields (ADR-0013), accept a `{name}`-style placeholder dialect that the loader substitutes at parse time. The variable namespace is segmented: project-level (`{package.name}`, `{package.version}` from `[package]`), per-item (`{item.name}`, `{item.source}`, `{item.output}` — valid only inside per-entry hook fields and `[build].<entry>` fields), and host-platform context (`{platform.os}`, `{platform.arch}` — mirroring GocciaScript's `Goccia.build.os` and `Goccia.build.arch` value vocabulary verbatim). Unknown placeholder names are a hard error at manifest load with the unknown name reported. The `{user}` / `{repository}` / `{ref}` template syntax already used in `[sources]` URL templates is a separate dialect on a disjoint surface — both use `{...}` delimiters because the source-of-truth ergonomics outweigh a one-character distinction we don't need, but no placeholder is valid in both contexts. The host-platform vocabulary mirror is implemented by vendoring `source/units/Goccia.Platform.pas` from GocciaScript verbatim (renamed to `source/Platform.pas` with `[LWPT patch]` markers) so that the OS / arch detection table is single-sourced across both projects and the canonical value list (`darwin` / `linux` / `windows` / `freebsd` / `netbsd` / `openbsd` / `android` / `aix` / `solaris` / `unknown`; `x86_64` / `aarch64` / `x86` / `arm` / `powerpc64` / `powerpc` / `unknown`) can't drift.

## Considered Options

### Scope of interpolation (Q7)

- **`[targets]` fields only, `{name}` + `{version}` only.** Narrowest reading of "string interpolation for build target config". Rejected because the hook surface (ADR-0011) immediately wants the same treatment — forcing literal strings in hooks after spending an ADR on hook ergonomics is a regression.
- **`[targets]` + hook fields, project vars only.** Better, but per-target context vars (`{target.name}` etc.) are the single biggest payoff: they make one shared script reusable across N targets without per-target ceremony. Without them, an `args = ["{target.output}"]` shared sign-each-target story becomes N copies of the same script with different hardcoded paths.
- **`[targets]` + hooks + per-target context vars.** Captures the per-target payoff but stops short of build-time host context.
- **`[targets]` + hooks + per-target + build host context (`{build.os}` / `{build.arch}`).** *Chosen.* Adds the eventual cross-compile-naming need (`output = "build/{name}-{build.os}-{build.arch}/{name}"`) at low cost and gives LWPT the same namespace shape as GocciaScript's runtime introspection surface.
- **All of the above + escape hatches (`{env.HOME}`, `{git.sha}`, `{date}`).** Rejected because each escape hatch breaks manifest hermeticity — same manifest, same commit, different build depending on environment. The legitimate use cases (release version stamps, git SHA in binaries) belong in a prebuild hook that writes a generated `.inc` — the manifest stays declaratively hermetic; the hook can do whatever it wants. (At the time this ADR was written, LWPT's own `scripts/embed.pas` was the canonical example. ADR-0015 retired it; the pattern survives — any user-authored `[prebuild]` hook fits the same shape.)

### Build-context names + values (Q8 / Q9)

- **Flat `{os}` and `{cpu}`.** The initial proposal in this design. Rejected after looking at the actual GocciaScript convention: GocciaScript uses `Goccia.build.os` and `Goccia.build.arch` (nested under `build`, and `arch` not `cpu`). Adopting different names — purely from cargo-cult intuition rather than checking the local mirror target — would have meant immediate divergence and a future rename to align.
- **Dotted `{build.os}` and `{build.arch}`.** *Chosen for naming.* Matches GocciaScript's `Goccia.build.<field>` access path field-for-field; sits naturally in the dotted-namespace placeholder shape we already have (`{target.name}` etc.).
- **Re-implement the OS / arch detection table inside LWPT.** Same constants, two copies. Rejected because the two projects' canonical value lists would drift silently the moment either adds a new platform (Haiku, RISC-V, s390x). The mirror only works if the *source of truth* is mirrored, not just the value vocabulary on one side.
- **Promote `Goccia.Platform.pas` immediately to a standalone package and depend on it.** The long-term graduation path. Rejected for the same reason as Semver's graduation: the bootstrap chain isn't ready yet, and the unit is trivial enough to vendor.
- **Vendor `Goccia.Platform.pas` → `source/Platform.pas`.** *Chosen for implementation.* Follows the Semver pattern: rename file + drop unit prefix + swap `{$I Goccia.inc}` for `{$I Shared.inc}` + record under the named-exception block in `docs/vendored.md`. Two consumers (GocciaScript + LWPT) share one source-of-truth file structure; future graduation is the symmetric move for both projects.

### Syntax delimiters (sub-question of Q7)

- **`${name}` (shell-style).** Rejected — invites shell-substitution mental model and the security concerns that ride along (history of every "shell injection in template" CVE).
- **`%name%` (Windows env-style).** Rejected — Windows-flavoured, conflicts with FPC's `%TARGET%` build variables in some contexts, looks foreign in a TOML manifest.
- **`${{name}}` (GitHub Actions style).** Rejected — heavier visual weight without a corresponding gain, GitHub-Actions-flavoured semantics (function calls, expression evaluation) that we explicitly don't want.
- **`{name}` (TOML-brace style).** *Chosen.* Matches the existing `[sources]` template syntax. Two dialects in one manifest reusing one delimiter is the trade we accept; the alternative — picking a *second* delimiter solely to disambiguate two dialects that already sit on disjoint surfaces — would be the strictly worse option for an internal-consistency win nobody's asking for.

### Validation timing (sub-question of Q7)

- **At-use time.** Substitute placeholders lazily when a field is read (during target build, during hook execution). Rejected because errors surface in the middle of operations rather than at load — a typo in `[targets].lwpt.output` would fail the build step, not the manifest parse, and the error wouldn't name the source line cleanly.
- **At manifest load.** *Chosen.* All placeholder substitution happens in `LoadManifest`'s post-parse pass. Unknown placeholders raise `EManifestError` naming the field, the unknown placeholder name, and the available namespace for that scope. Manifest with broken interpolation fails `lwpt install`, `lwpt build`, and `lwpt test` identically — single error site, single error shape, one less surface for "but it worked on my machine".

## Consequences

- **Placeholder namespace, fully enumerated:**

  | Location | Available placeholders |
  | --- | --- |
  | `[targets].<name>.<field>` (any string field) | `{name}`, `{version}`, `{target.name}`, `{target.source}`, `{target.output}`, `{build.os}`, `{build.arch}` |
  | `[targets].<name>.{prebuild,postbuild}.<hook>.<field>` | same — per-target context active |
  | `[preinstall]` / `[postinstall]` / `[prebuild]` / `[postbuild]` / `[pretest]` / `[posttest]`<br>`.<hook>.<field>` | `{name}`, `{version}`, `{build.os}`, `{build.arch}` — `{target.*}` is a hard error here (whole-build hooks have no target in scope) |
  | `[sources].<name>.<field>` (URL templates) | `{user}`, `{repository}`, `{ref}` only — the existing dialect, unchanged |
  | anywhere else (`[package]`, `[dependencies]`, `[format]`, `[lwpt]`, `[version]`) | no interpolation — literal strings only |

- **Syntax is exactly `{name}`** — single curly braces, identifier characters (`[a-zA-Z][a-zA-Z0-9_.]*`) inside, no escaping inside the brace pair. To produce a literal `{` in a manifest string, double it: `{{` substitutes to `{`. (Mirrors the existing `[sources]` template behaviour.)

- **Resolution order is two-pass.** Pass 1 resolves project-level vars (`{name}`, `{version}`) and build-context vars (`{build.os}`, `{build.arch}`) in every interpolatable field, including the values of `[targets].<name>.source` / `output`. Pass 2 resolves per-target vars (`{target.name}` etc.) using the post-pass-1 target values as their source. This means `[targets].foo.postbuild.sign.args = ["{target.output}"]` correctly sees the version-stamped path even when `output = "build/{name}-{version}/foo"`.

- **Unknown placeholder = manifest-load error with three pieces of context:** the field path (`[targets].lwpt.output`), the unknown name (`{verison}`), and the available-in-scope list (`{name}`, `{version}`, `{target.name}`, `{target.source}`, `{target.output}`, `{build.os}`, `{build.arch}`). Typos surface immediately with the candidate fix one character away in the error message.

- **`{target.*}` outside a per-target context is a manifest-load error**, with a message naming the scope. Whole-build hooks have no target — they run once per `lwpt build` regardless of how many targets compile. Adding a fallback (resolve `{target.name}` to "all" or the first target) would create the kind of silent-mode-switch that bites at 2am.

- **`source/Platform.pas` is vendored** from `~/Documents/Github/GocciaScript/source/units/Goccia.Platform.pas`. Patches: unit name (`Goccia.Platform` → `Platform`), include swap (`{$I Goccia.inc}` → `{$I Shared.inc}`). Same `[LWPT patch]` marker pattern as `Semver.pas` and the CLI namespace. The unit ships two getters (`GetBuildOS`, `GetBuildArch`) — LWPT's interpolation evaluator calls those directly when populating `{build.os}` / `{build.arch}`. Adding a new platform requires changing one file in *both* projects; the rename is mechanical enough that a future GocciaScript sync diff would be obviously a one-line value-list extension.

- **The `Goccia.build` mirror is a named convention, not a one-time copy.** Both projects' canonical OS / arch value lists track each other manually. Adding `riscv64` to one without the other is a known-acceptable divergence, but explicit (each side names the other in its respective unit / docs). `docs/vendored.md`'s named-exception block lists `Platform.pas` alongside `Semver.pas` to make this visible to reviewers.

- **Placeholders compose with hook execution naturally.** A per-target postbuild hook like:

  ```toml
  [targets]
  lwpt = { source = "source/lwpt.pas",
           output = "build/{name}-{build.os}-{build.arch}/{name}",
           postbuild = { sign = { script = "scripts/sign.pas",
                                  args   = ["{target.output}"] } } }
  ```

  resolves at manifest load to (on a darwin/aarch64 host):

  ```text
  source = source/lwpt.pas
  output = build/lwpt-darwin-aarch64/lwpt
  postbuild.sign.script = scripts/sign.pas
  postbuild.sign.args   = ["build/lwpt-darwin-aarch64/lwpt"]
  ```

  No runtime substitution layer — by the time `CmdBuild` or `RunHooks` reads the manifest, every string is concrete.

- **The decision forecloses** environment-variable interpolation (`{env.*}`) and git-state interpolation (`{git.*}`) in manifest fields. Both have legitimate use cases; both belong in a prebuild hook that writes a generated `.inc` file, where the script can do anything it wants without polluting the manifest's hermeticity. Adding them later remains possible but would require an ADR-cited reversal of the hermeticity principle.

- **The decision opens** trivially adding more `{build.*}` fields as GocciaScript adds them (compiler version? endianness? pointer width?), additional `{target.*}` fields as targets grow new properties (`{target.kind}` if we ever distinguish library / binary), and a `{lwpt.*}` namespace for toolkit-internal facts (`{lwpt.version}`, `{lwpt.modules_dir}`) if a real use case emerges. All non-breaking extensions of the same shape.
