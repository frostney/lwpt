# Graduation extraction — `packages/<name>/` for HTTPClient, CLI, Semver, TOML

> **Amended by [ADR-0015](./0015-drop-export-testing-becomes-workspace-package.md):** `testing` joined as the fifth workspace package in an earlier wave that retired `lwpt export` + the embedded-`TestingPascalLibrary` blob. Same shape as the four below (own `lwpt.toml`, own `source/`, own self-test, bundled `Shared.inc`); auto-discovered by the existing `[workspaces] include = ["packages/*"]` glob in the root manifest.

The graduation arc from [ADR-0003](./0003-vendored-permanent-fork-graduation.md) reaches its in-repo extraction stage. Four units — HTTPClient, CLI (the namespace bundle), Semver, TOML — move out of `source/` into `packages/<name>/`, each as a standalone Pascal project with its own `lwpt.toml`, its own `source/` tree, its own tests, and its own copy of shared utilities (`StringBuffer.pas`, `Shared.inc`) per the bundled-shared-utils decision in Q14. LWPT itself becomes a consumer of these packages via local-path `[dependencies]` (`./packages/<name>`); `lwpt install` copies each into `.lwpt/modules/<name>/` and the cfg emitter wires `-Fu/-Fi` to each dep's own `units` array. The bootstrap path (`bootstrap.sh` / `bootstrap.bat` / `scripts/bootstrap.pas`) adds explicit `-Fu` flags for each `packages/<name>/source/` so cold compilation works before `lwpt install` ever runs. Two prerequisites surfaced during the extraction work and are fixed in the same wave: (1) the cfg emitter previously wrote `-Fu<modules-root>/<dep>` ignoring the dep's own `units` array, so any dep with `units = ["src"]` had its `.pas` files invisible to FPC — fixed by adding `UnitSubdirs` to `TResolveNode` + `TResolved` and emitting `-Fu/-Fi` for each `<modules-root>/<dep>/<subdir>` entry; (2) `LoadManifest`'s returned `TManifest` record relied on the caller's variable being zeroed between calls, but FPC's value-return convention shares storage with the caller, so dynamic-array fields (notably `Result.Units`) accumulated across transitive-resolver loads — fixed by explicit `Result := Default(TManifest)` at function entry. Without (1), nothing built. Without (2), `branch-a` ended up with `UnitSubdirs = ["src"]` but `leaf-c` with `UnitSubdirs = ["src", "src", "src"]` and the cfg duplicated entries proportionally.

## Considered Options

### Granularity of shared utilities (Q14)

- **Six packages — npm/cargo style.** HTTPClient, CLI, Semver, TOML + `packages/stringbuffer/` + `packages/fileutils/` as separate micro-packages. Zero duplication; clean dep graph. Rejected: ~200 lines of utilities don't justify six manifests, six version bumps, six install-hash entries. The npm `left-pad` ecosystem is the cautionary tale, not the model.
- **Five packages — bundled "shared" mini-package.** Four named + `packages/shared/` containing `StringBuffer.pas`, `FileUtils.pas`, `Shared.inc`. Rejected: invents a fifth package whose only purpose is to hold ~200 lines; `shared` doesn't carry meaning (what makes it "shared"? — it's just utilities two other packages happen to need).
- **Four packages, source/ keeps shared utilities.** HTTPClient + CLI assume the consumer has `StringBuffer.pas` on the search path. Rejected: breaks standalone-ness. A future user of just `httpclient` would have to discover the implicit dep.
- **Four packages, bundled shared utils.** *Chosen.* `packages/httpclient/source/` ships its own `StringBuffer.pas` + `FileUtils.pas` + `TransportSecurity.pas`. `packages/cli/source/` ships its own `StringBuffer.pas`. ~100 lines of duplication; each package is fully self-contained with zero inter-package coordination. The shared units are tiny + stable; the duplication footprint is acceptable.

### Directory location

- **`vendor/` at repo root** (initially picked). Aligns with Go's `vendor/` + Composer's `vendor/`. Rejected after grilling: `vendor/` conflicts with the previously-deprecated "vendor dir" antipattern called out in CONTEXT.md's `Toolkit state` glossary entry — the old term referred to consumer-project dep trees, the new one would be monorepo-style LWPT-owned packages. Disambiguating is doable but adds glossary debt.
- **`packages/` at repo root.** *Chosen.* Generic, no ambiguity with prior terminology, matches the npm-cargo intuition that monorepo subpackages live under `packages/`. CONTEXT.md gains a new `Package (graduated)` glossary entry pointing at this directory.
- **`lib/<name>/` or nested under another parent.** Rejected: extra namespace level without payoff.

### Self-consumption mechanism

- **Special-case the LWPT root manifest** to skip dep resolution for packages that live in-tree (use `packages/<name>/source/` directly via `-Fu` without ever copying to `.lwpt/modules/`). Rejected: introduces a special path that diverges from how every other project consumes deps. Hash verification (`--frozen`) would have a self-shaped hole.
- **Local-path `[dependencies]`** entries (`./packages/httpclient`). *Chosen.* The resolver's existing `skLocal` handling does the work — `CopyDirTree(packages/httpclient, .lwpt/modules/httpclient)`. After install, the cfg points at `.lwpt/modules/httpclient/source/`. `lwpt install --frozen` verifies hashes the same as any other dep. Self-consumption uses zero new mechanism.

### Test locations (Q16)

- **Tests stay in `source/`.** Discovery doesn't change. Rejected: a future graduate that moves `packages/httpclient/` to its own repo would have to re-acquire its tests separately.
- **Hybrid — unit tests with package; integration tests in `source/`.** Rejected: splits arbitrarily; hard to predict where the next test belongs.
- **Tests move with the package.** *Chosen.* `HTTPClient.Test.pas` + `Tests.HTTPMockServer.pas` → `packages/httpclient/source/`; `Semver.Test.pas` → `packages/semver/source/`. `CmdTest`'s `CollectTestFiles('.', Tests)` already walks the whole tree recursively (skipping only `.lwpt`/`build`/`.git`), so `packages/<name>/source/*.Test.pas` is picked up without code changes. When a package graduates to its own repo, its tests come with it.

### Cfg-emitter prerequisite

- **Leave the cfg-emitter bug alone.** Rejected: the existing test fixtures pass because they assert structure not compilation, but a real `lwpt install` of a dep with `units = ["src"]` would produce an unusable cfg. The packages/ extraction immediately depends on the fix.
- **Fix the emitter.** *Chosen.* `TResolveNode.UnitSubdirs` populated from `ChildMan.Units` during BFS; `TResolved.UnitSubdirs` carried through; `WriteCfg` emits one `-Fu/-Fi` pair per subdir. Fallback (dep with no `units` declared) keeps the legacy single-path behaviour for backwards compat.

### `LoadManifest` Result-init prerequisite

- **Leave the accumulation bug alone.** Rejected: shipping `packages/` would surface this immediately as duplicated cfg entries (1, 2, 3, …).
- **Explicit `Result := Default(TManifest)` at function entry.** *Chosen.* Resets every field (including dynamic-array references) regardless of caller's variable state. The fix is one line + a comment explaining FPC's hidden-var-arg behaviour. Caught (and named) in the cfg-fix verification.

## Consequences

- **`packages/{httpclient,cli,semver,toml}/`** each contain:
  - `lwpt.toml` (`name`, `version = "0.1.0"`, `units = ["source"]`)
  - `source/` (the `.pas` files moved out of LWPT's `source/`, plus bundled shared utils + `Shared.inc`)
  - Tests where they exist — `HTTPClient.Test.pas`, `Tests.HTTPMockServer.pas`, `Semver.Test.pas` move with their package.

- **`source/` slims down to LWPT-owned units + the not-yet-graduated remainder**: `lwpt.pas`, `LWPT.Core.pas`, `LWPT.Format.pas`, `LWPT.GitProtocol.pas`, `Platform.pas`, `TestingPascalLibrary.pas`, the embedded testing-library `.inc`, `LWPT.Core.Test.pas`, `LWPT.Format.Test.pas`, `Tests.TestingPascalLibrary.Canary.Test.pas`, `Shared.inc`.

- **Root `lwpt.toml` declares the packages as local-path deps**:

  ```toml
  [dependencies]
  httpclient = "./packages/httpclient"
  cli        = "./packages/cli"
  semver     = "./packages/semver"
  toml       = "./packages/toml"
  ```

  The leading `./` is required because the dep-source parser treats bare `packages/httpclient` as a GitHub `owner/repo` shorthand (the path parser keys off `./`, `../`, `/`, `~/`, or the explicit `local:` prefix).

- **Bootstrap scripts add explicit `-Fu` paths** for each `packages/<name>/source/`. The cold compile path (no `lwpt install` prerequisite) finds everything it needs:

  ```sh
  fpc -Mdelphi -Sh \
    -Fusource -Fisource \
    -Fupackages/httpclient/source -Fipackages/httpclient/source \
    -Fupackages/cli/source        -Fipackages/cli/source \
    -Fupackages/semver/source     -Fipackages/semver/source \
    -Fupackages/toml/source       -Fipackages/toml/source \
    ...
  ```

  Same paths in `bootstrap.bat` (Windows backslashes) and in `scripts/bootstrap.pas`'s `RunProcess('fpc', [...])` invocation.

- **Steady-state `lwpt build` reads packages from `.lwpt/modules/<name>/source/`** via the cfg emitted by `lwpt install`. The bootstrap-vs-steady-state duplication (`packages/<name>/source/X.pas` AND `.lwpt/modules/<name>/source/X.pas`) is intentional — bootstrap can't depend on install, install gives us hash verification + the standard dep treatment.

- **The cfg emitter now respects per-dep `units` arrays.** `WriteCfg` iterates `AResolved[i].UnitSubdirs` and emits one `-Fu/-Fi` pair per subdir under the dep's modules root. Fallback to `UnitDir` itself when a dep has no `units` declared keeps older fixtures working.

- **`LoadManifest` returns a fresh-zeroed `TManifest` on every call.** Documented in a code comment as an FPC value-return-convention quirk (Result IS the caller's variable; without explicit reset, dynamic-array fields survive across calls).

- **`CompilePascal` inherits `@lwpt.cfg`** when present, so per-test compiles see the same dep search paths that `lwpt build` uses. Without this, every test that transitively imports a package's unit fails with `Can't find unit X`.

- **`[format] exclude` collapses** from the previous list of individual `source/<unit>.pas` entries to:
  ```toml
  exclude = [
    "source/Platform.pas",
    "source/TestingPascalLibrary.pas",
    "source/Shared.inc",
    "source/LWPT.Embedded.TestingLibrary.inc",
    "packages/**",
  ]
  ```
  Each package can grow its own per-package `lwpt format` story when ready; the root formatter doesn't reach into them.

- **`CONTEXT.md` gains a `Package (graduated)` glossary entry** disambiguating from the `Vendored` term (which now describes the broader notion) and from `Module` / `.lwpt/modules/` (the installed-dep-tree term). `Vendored` is updated to acknowledge that vendored units mostly live in `packages/<name>/` post-ADR-0014, with `source/` holding the remainder.

- **`docs/vendored.md` reorganises** its table — paths change from `source/<unit>.pas` to `packages/<name>/source/<unit>.pas` for the four graduates. The named-exception treatment (CLI prefix-strip, Semver rename, Platform rename) is preserved, just at the new paths. Patch markers in code move with the files. *(update: `docs/vendored.md` is now `docs/packages.md` per ADR-0017; the "named exception" + "patch marker" framing was retired in the same wave.)*

- **Subcommand surface, hook surface, placeholder namespace are unchanged.** None of the prior ADR work touches package boundaries directly; the extraction is structural and additive.

- **The decision forecloses** keeping graduated units inline under `source/` (they're physically gone); reverting would require putting them back AND reverting the cfg + LoadManifest fixes. The forks-and-merges have no path back.

- **The decision opens** Phase 2 of the graduation roadmap: `packages/<name>/` moving out of LWPT's repo entirely into standalone repos. The local-path entries in `[dependencies]` flip to git-host entries; the `packages/<name>/` dir is removed. No further LWPT-side code changes required (the cfg / install / resolve pipeline already treats them uniformly with any other dep).

---

## Amendment: Symlink/junction for monorepo deps

The initial extraction copied each `./packages/<name>/` tree into `.lwpt/modules/<name>/` byte-for-byte. After it landed, two observations made the case for a refinement:

1. **Byte-for-byte duplication is wasteful.** Every file in `packages/httpclient/source/` exists twice on disk (`.lwpt/modules/httpclient/source/`). Edit-then-test cycles require a re-install for the cfg to pick up changes.
2. **`packages/` is by definition a monorepo arrangement.** The dep target is inside the project root, committed alongside the consumer, moves with the consumer. The symlink-fragility risks that justify "copy by default" (link target disappearing, paths breaking on move) don't apply.

The npm-ecosystem precedent informed the implementation choice — npm + pnpm both symlink on Unix and use NTFS junctions on Windows. Junctions are NOT symlinks (they're a separate NTFS reparse-point kind for directories only) but they're the right answer for Windows because they don't require Developer Mode or admin privileges. pnpm specifically engineered around this in 2016 (issue #6 → PR #269).

### Decision

**Local-path deps install as a symlink (Unix) or NTFS junction (Windows) IF the resolved absolute path is inside the project root. Otherwise (external-path deps: `../../X`, `/abs/X`), the existing recursive-copy path is preserved.** Per-dep determination; a single project can have both kinds. Unix symlink targets are written relative to the link's parent directory (for example `.lwpt/modules/cli -> ../../packages/cli/`), matching the npm/pnpm/Bun-style in-tree link shape and preserving zero-install after a fresh clone in a different absolute path.

**Junction creation on Windows uses direct OS calls — no `mklink /J` shell-out.** `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS`, then `DeviceIoControl` with `FSCTL_SET_REPARSE_POINT` carrying an `IO_REPARSE_TAG_MOUNT_POINT` `REPARSE_DATA_BUFFER`. ~80 lines of Windows API in `LWPT.Core.pas`'s `CreateDirLink` function. The TProcess-spawn alternative would have been simpler but adds latency + couples us to `mklink` being present in the PATH (it's a CMD builtin so always is, but the indirection adds nothing).

### Considered options

- **Symlink everywhere; hard error on Windows if the OS refuses.** Rejected: every Windows user without Developer Mode hits a wall. Junctions exist exactly to solve this without privilege escalation; using them is no-cost.
- **Symlink on Unix; copy on Windows.** Rejected: gives up half the win for cross-platform symmetry that isn't required. LWPT's developer audience is Pascal — many on Windows. The disk-savings + edit-immediacy story is what makes the symlink decision worth the implementation work.
- **`[lwpt]`-setting controlled** (`monorepo-link = "auto" | "symlink" | "copy"`). Rejected: a setting to flip a non-decision. "Auto" is the right default; the override is the kind of thing nobody actually flips.
- **Silent copy fallback** when symlink/junction fails. Rejected: hides bugs. The current implementation **does** fall back to copy with a `warning: link failed for X; falling back to copy` line — the fallback is visible, not silent. Bugs in the link path get noticed.

### Safety caveat: Windows junction + `rm -rf`

Documented by pnpm's [issue #10707](https://github.com/pnpm/pnpm/issues/10707): PowerShell's `Remove-Item -Recurse -Force` and Git Bash's `rm -rf` **follow NTFS junctions into the target directory and delete files outside the intended path**. This is a Windows-platform behaviour, not an LWPT bug, but it's the kind of footgun that LWPT must address explicitly:

- **Internal**: LWPT's own `WipeInstalledDep` uses `IsDirSymlinkOrJunction` to detect a link and `RemoveDirLink` (which on Windows calls `RemoveDirectoryW`, documented to remove the reparse point itself rather than recurse) to remove it safely. We never walk through a junction.
- **External**: a user running `Remove-Item .lwpt -Recurse -Force` on a Windows machine where `.lwpt/modules/httpclient` is a junction to `packages/httpclient/` would lose `packages/httpclient/source/*.pas`. This is documented prominently in `docs/architecture.md` with the safe alternative (`cmd.exe /c "rmdir /S /Q .lwpt"`).

### Consequences

- **`source/LWPT.Core.pas` gains four helpers**: `IsPathInside`, `IsDirSymlinkOrJunction`, `RemoveDirLink`, `CreateDirLink`, plus the orchestrator `WipeInstalledDep`. Each is conditionally compiled per platform (`{$IFDEF UNIX}` / `{$IFDEF MSWINDOWS}`). The Unix path creates relative symlinks; the Windows path uses absolute NTFS junction targets via `CreateFileW` / `DeviceIoControl` / `RemoveDirectoryW` / `GetFileAttributesW` from FPC's bundled `Windows` unit; no third-party headers.
- **`FetchToCache` signature grows by one parameter — `AProjectRoot`** — the absolute directory of the root manifest. `CmdInstall` passes `ExtractFilePath(ExpandFileName(AManifestPath))`. The skLocal branch tests `IsPathInside(AProjectRoot, ExpandedLocalPath)` and picks link-vs-copy accordingly.
- **`ResolveGraph` signature grows by one parameter too** — propagating `AProjectRoot` to `FetchToCache`.
- **Per-dep log lines**: `linked httpclient` / `copied my-fork` instead of the silent prior behaviour. The user sees what shape the install took.
- **`WipeInstalledDep` replaces `WipeDir(AUnitDir)` in the skLocal branch.** Detects links + unlinks them; never recurses through a link. Plain directories still go through `WipeDir` as before.
- **Hash verification (`--frozen`) follows the link.** A user who edits `packages/httpclient/source/X.pas` and runs `lwpt install --frozen` gets a hash mismatch — correct, the project state has drifted. Re-running `lwpt install` (non-frozen) re-records the new hash.
- **External-path deps unchanged.** Diamond fixture's `../a`/`../b`/`../c` still copy — they're outside `tests/fixtures/diamond/root/`. The integration tests pass without modification; the new `IsPathInside` check correctly returns False for them.
- **The decision opens** per-package-format support in a future wave (each `packages/<name>/lwpt.toml` could grow its own `[format]` scope), and the future graduation step (packages move to standalone repos) — the local-path → git-host flip at that point keeps the link/copy decision irrelevant (network deps always extract from archives).

---

## Amendment: Workspace auto-discovery

The first two waves (in-repo extraction + symlink/junction for monorepo deps) made the monorepo layout work but kept the declaration verbose — every `packages/<name>/` had to be explicitly listed in the root `[dependencies]` block with a `./packages/<name>` local-path entry. With four packages today, this is four lines; with twenty packages it would be twenty lines of mechanical declaration. The JS-ecosystem solution (npm/yarn/pnpm/bun) is a `workspaces` field of glob patterns + auto-discovery. This amendment mirrors that pattern.

### Decision

**Add a `[workspaces]` section to the root manifest with `include` + `exclude` glob arrays.** Each `include` glob is matched against directories under the project root; each matching dir that carries its own `lwpt.toml` becomes a workspace, identified by its `[package].name`. Discovered workspaces are auto-installed (added as virtual local-path deps on `Result.Deps` if not already explicitly declared). Inter-workspace dependencies use the **`workspace:<spec>` protocol** (`workspace:*`, `workspace:^0.1.0`, etc.) — strictly resolved against the discovered workspace set; never falls through to a registry / git-host lookup.

### Considered options

**Q19 — Manifest shape**

- **Top-level field** (`workspaces = ["packages/*"]`, strict npm/yarn/bun mirror). Rejected: the LWPT manifest is uniformly section-per-concept (`[format]`, `[targets]→[build]`, `[generated]`, `[sources]`, the hook sections). A bare top-level non-section key would be the only one — unnecessarily exceptional.
- **Field on `[package]`** (`[package].workspaces = [...]`). Rejected: `[package]` is about project identity; workspaces are topology. Locality argument is weak.
- **`[workspaces]` section with `include` + `exclude` arrays.** *Chosen.* Mirrors `[format] include/exclude` exactly; same glob syntax (`*` / `**` / `?` + literal paths); same parser. Extensible (room for future fields like `default-version`, `inherit-deps`).

**Q20 — Inter-workspace dep syntax**

- **Auto-resolve by name** (`httpclient = "*"` — if name matches a workspace, use it; else registry). Rejected: silent fall-through to registry when a workspace is renamed/removed could install the wrong package — a real footgun. The strict semantics of `workspace:` exist precisely to prevent this.
- **Both `workspace:` (strict) and bare-name (auto-resolve)**. Rejected: a bare `httpclient = "*"` would have ambiguous source-of-truth (workspace if present, registry otherwise) — a runtime decision the manifest reader can't predict statically.
- **`workspace:<spec>` protocol, strict semantics.** *Chosen.* If `workspace:X` references a name with no matching workspace, hard error naming the available workspace set. Mirrors yarn / pnpm / bun. Modern norm in the JS ecosystem (post-npm-RFC-0026).

**Q21 — Are workspaces installed automatically?**

- **Explicit-reference required** — workspaces declared but only installed if root's `[dependencies]` lists them via `workspace:*`. Rejected: forces double-bookkeeping for the common case ("I have a monorepo; install/build/link everything").
- **Hybrid** — workspaces auto-installed on disk but only added to the cfg `-Fu` paths if explicitly referenced. Rejected: over-engineers, separates "installed" from "linked into build path" for a case nobody asked for.
- **Auto-install all matched workspaces.** *Chosen.* Mirrors bun's umbrella-project model. Root's `[dependencies]` stays for external deps (registries, git-host, external-path locals); the `[workspaces]` section is the monorepo-internal counterpart.

### Consequences

- **`[workspaces]` is a recognised top-level section** added to LWPT's `KNOWN_SECTIONS` allowlist, parsed for **all manifests** (root + dep) — the same mechanism as `[package]` and `[dependencies]`. Unlike hook sections (which fire arbitrary code and are root-only as a supply-chain measure), workspaces are pure code-organisation declarations (local-path resolution only, no arbitrary execution); parsing them in nested workspace manifests is safe and enables yarn-berry-style nested worktrees. The resolver enqueues a nested workspace's auto-added virtual deps the same way it would any explicit dep, so a workspace inside `packages/cli/` could itself declare `[workspaces] include = ["sub/*"]` and the sub-workspaces would install transitively.

- **`workspaces` is on the `RESERVED_SUBCOMMAND_NAMES` list** alongside `package`, `dependencies`, `sources`, `build`, `version`, `lwpt`, `format`, `generated` (and the eight subcommand names). The list now has two halves: subcommand names (the original ADR-0013 use case — preventing `lwpt run <subcmd>` ambiguity) and configuration-section names (defensive: ensuring a section with one of these names + a `script` field can never be silently re-interpreted as a run-script even under a future code reordering). The KNOWN_SECTIONS check already structurally prevents this, but the explicit reservation documents the intent in code.

- **Local-path dep resolution is preserved unchanged.** Explicit `[dependencies] httpclient = "./packages/httpclient"` style entries continue to work; `[workspaces]` auto-discovery is **additive**, not replacement. The auto-add loop skips any workspace whose name already appears in `[dependencies]` — the explicit entry wins. So a manifest with BOTH `[workspaces] include = ["packages/*"]` AND `[dependencies] foo = "./packages/foo"` gets one `foo` entry (the explicit one) plus auto-added entries for every other workspace under `packages/`. Verified by smoke test: scratch project with explicit + auto-discovered entries produces exactly one entry per name.

- **Discovery shape:**
  ```toml
  [workspaces]
  include = ["packages/*"]
  exclude = ["packages/legacy/*"]   # optional
  ```
  Each `include` glob walks the project tree relative to the root manifest's directory; each matching dir that contains a `lwpt.toml` becomes a workspace. `exclude` globs subtract from the set (same semantics as `[format].exclude`). Duplicate workspace names (two workspaces with the same `[package].name`) raise `EManifestError` at load.

- **Auto-add to `Result.Deps`**: each discovered workspace not already present in the explicit `[dependencies]` block becomes a virtual local-path entry with `SrcKind = skLocal`, `SrcLocator = <resolved path>`, `SrcOriginal = "workspace:auto"` (for traceability — the lockfile shows the provenance). Explicit entries with the same name take precedence (the user's override wins). The resolver's BFS then handles them like any other local-path dep — symlinked via the ADR-0014-amendment-"Symlink/junction" path since they're inside the project root.

- **`workspace:<spec>` source protocol**: parsed by the existing `ParseDependencySourceCore` as a new `TSourceKind.skWorkspace` variant. The trailing spec (`*`, `^0.1.0`, exact version) lives in `TDependency.VersionSpec`; `SrcLocator` stays empty until the resolver fills it. At BFS time, `FetchToCache` looks up the dep name in `ARootMan.Workspaces` — found → rewrite to a synthetic `skLocal` dep against the workspace path + recurse into the standard local-install branch (which links). Not found → `EFetchError` naming the available workspaces.

- **`AWorkspaces` plumbed through `ResolveGraph` → `FetchToCache`** signatures. `CmdInstall` passes `Man.Workspaces`. The workspace set is available wherever a dep gets fetched (both for root-declared `workspace:` deps and for sibling-workspace-declared `workspace:` deps, since the resolver visits both root and dep manifests).

- **Migration of the repo's own `lwpt.toml`**: the four explicit `[dependencies]` local-path entries collapse to one `[workspaces] include = ["packages/*"]` line. Same on-disk shape after install (each workspace still symlinks into `.lwpt/modules/<name>/`); same cfg output.

- **Version-spec enforcement for `workspace:^X.Y.Z`** is deferred — today's implementation accepts the spec and resolves the workspace by name without checking the workspace's `[package].version` against the range. This is consistent with the resolver's pre-existing treatment of `skLocal` (version specs are forbidden for local-path deps). When the resolver grows version-vs-spec checks for workspaces, the `Result.Workspaces[i].Version` field is already populated for the comparison.

- **Cycles between workspaces** are detected by the BFS's existing visited-set logic (TouchNode + IsNew guard). A `workspace:` cycle resolves to the same lookup multiple times but doesn't re-enqueue.

- **`[format] exclude` still covers `packages/**`** — auto-discovered workspaces don't accidentally fall into the root formatter's scope.

- **The decision forecloses** silent fall-through from `workspace:` to a registry / git-host (the strict semantics are a feature, not a bug); reverting would re-open the "renamed workspace silently swapped for registry package" attack vector.

- **The decision opens** per-workspace operations (e.g. `lwpt --filter=cli test` to run tests across selected workspaces) — npm/yarn/bun all have these and the workspace-name index is now available for filtering. No code written for this in this wave; the data is there when someone wants the feature.
