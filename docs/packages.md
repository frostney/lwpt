# Packages

The table of LWPT's canonical packages, their consumers (LWPT itself and GocciaScript-future), the divergence policy for the GocciaScript-adoption transition window, and the bootstrap chicken-and-egg story.

> An earlier version of this file lived at `docs/vendored.md` and treated GocciaScript as an upstream that LWPT vendored from. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md) that framing was wrong: LWPT and GocciaScript are sister projects under the same owner, with LWPT's `packages/<name>/` already canonical for every shared utility. This file is the renamed + rewritten version under the corrected model.

## Executive Summary

- **Five packages** live in LWPT's monorepo today under `packages/<name>/`: `httpclient`, `cli`, `semver`, `toml`, `testing`. Each is a standalone Object Pascal project — own `lwpt.toml`, own `source/`, own tests, own version (semver 2.0.0). LWPT itself consumes them via the root manifest's `[workspaces] include = ["packages/*"]` glob; `lwpt install` symlinks each into `.lwpt/modules/<name>/`.
- **Plus a remainder in `source/`**: `Platform.pas` (still LWPT-internal — extraction candidate for `packages/platform/`) and `Shared.inc` (the FPC mode + switches include — kept as a project-root utility, with each package bundling its own copy under `packages/<name>/source/Shared.inc` for self-containment).
- **LWPT is the canonical source** for every package's content. Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md) there is no upstream to defer to: LWPT and GocciaScript are sister projects co-owned; LWPT's packages came from GocciaScript historically but have evolved past those original copies (byte-safety fixes in HTTPClient; prefix-strip + dead-code removal in CLI; rename + inlined deps in Semver; rename + parser-class refactor in TOML; etc.).
- **GocciaScript is the first named consumer**, committed to Path A adoption (full toolchain migration to `lwpt build / install / test / format`). The migration is GocciaScript-side multi-wave work; ADR-0017 commits to the direction, not the timeline.
- **Divergence policy during the transition**: GocciaScript's older copies of the LWPT-canonical units are **frozen** pending adoption. All future improvements land in LWPT-canonical only. Backports happen only on demand for P0 bugs, with the LWPT-canonical version always landing first.
- **Bootstrap chicken-and-egg**: LWPT cannot fetch its own deps without HTTPClient existing. Today this is satisfied by `packages/httpclient/source/` being on the bootstrap fpc invocation's `-Fu` path; once `build/lwpt` exists, the full package system works.
- **No patch markers** in source. Per ADR-0017's "No patch markers" Hard Constraint, the codebase has no `{ [gpm patch] }` or `{ [LWPT patch] }` syntax — git history is the canonical record of every change. The historical explanations of *why* the code looks the way it does survive as plain Pascal comments.
- **No drift-check infrastructure.** With packages canonical-at-LWPT (not vendored from elsewhere), there's nothing external to drift against. The transition-window divergence with GocciaScript is documented here as a known state, not a defect to actively monitor.

## The package set

| Package | Location | Origin | LWPT-canonical state vs GocciaScript's older copy |
|---------|----------|--------|---------------------------------------------------|
| `httpclient` | `packages/httpclient/source/HTTPClient.pas`, `TransportSecurity.pas`, `FileUtils.pas`, `StringBuffer.pas`, `Tests.HTTPMockServer.pas`, `HTTPClient.Test.pas` | Co-developed with GocciaScript; HTTPClient grew the byte-safety accumulator in LWPT; TransportSecurity / FileUtils / StringBuffer unchanged from GocciaScript copies | `HTTPClient.pas` diverged (LWPT ahead — byte-safety fixes); rest identical |
| `cli` | `packages/cli/source/CLI.Help.pas`, `CLI.Options.pas`, `CLI.Parser.pas`, `CLI.Subcommands.pas` (LWPT-original), `CLI.Prompts.pas` (LWPT-original), `StringBuffer.pas` (bundled copy) | `CLI.*` family co-developed; LWPT canonicalised the namespace (stripped `TGoccia*` prefix from public types, dropped GocciaScript-engine-specific options as dead code, widened `CLI.Parser`'s space-separated option parsing). Subcommands + Prompts are LWPT-original. | `CLI.Options.pas` + `CLI.Parser.pas` diverged (LWPT ahead — prefix-strip + dead-code drop + parser widening); `CLI.Help.pas` minor diverge (`{$I Goccia.inc}` → `{$I Shared.inc}`); Subcommands + Prompts absent in GocciaScript |
| `semver` | `packages/semver/source/Semver.pas`, `Semver.Test.pas` | Renamed from GocciaScript's `Goccia.Semver.pas`. The single needed constant (`MAX_SAFE_INTEGER`) was inlined from the deleted `Goccia.Constants.NumericLimits` dependency. | Diverged (LWPT ahead — rename + prefix-strip + inlined constant) |
| `toml` | `packages/toml/source/TOML.pas`, `OrderedStringMap.pas`, `BaseMap.pas` | TOML refactored in LWPT (parser-class shape; renamed from `Goccia.TOML.pas`). `OrderedStringMap` + `BaseMap` co-developed unchanged. | `TOML.pas` diverged (LWPT ahead — rename + parser refactor); `OrderedStringMap.pas` + `BaseMap.pas` identical |
| `testing` | `packages/testing/source/TestingPascalLibrary.pas`, `TestingPascalLibrary.Test.pas` (canary), `Shared.inc` (bundled copy) | Co-developed assertion + suite + runner framework. Was previously an embedded blob inside the LWPT binary served via the (now-retired) `lwpt export testing` subcommand; graduated to a workspace package per [ADR-0015](./adr/0015-drop-export-testing-becomes-workspace-package.md). | Identical (no LWPT-side fixes pending) |
| `source/Platform.pas` | `source/Platform.pas` (LWPT-internal; extraction candidate) | Renamed from GocciaScript's `Goccia.Platform.pas`. `{$I Goccia.inc}` swapped for `{$I Shared.inc}`. **Value vocabulary** (`darwin` / `linux` / `windows` etc.) is mirrored verbatim with GocciaScript's `Goccia.build.os` global per the [ADR-0012](./adr/0012-manifest-placeholder-interpolation.md) platform-placeholder design; the access path diverges (TOML `{platform.os}` ↔ JS `Goccia.build.os`). | Diverged (LWPT ahead — rename + include swap); GocciaScript still has `source/units/Goccia.Platform.pas` |
| `source/Shared.inc` | `source/Shared.inc` | Co-developed; each `packages/<name>/source/` also vendors its own copy for self-containment per [ADR-0014](./adr/0014-packages-extraction.md)'s bundled-shared-utils decision. | Identical |

## Divergence — what GocciaScript needs to catch up on

Per the freeze policy (ADR-0017): **all the below are LWPT-canonical; GocciaScript will pick them up via Path A adoption**. New improvements only land in LWPT.

| GocciaScript path | LWPT-canonical path | Status | Notes |
|------|---------------------|--------|-------|
| `source/shared/HTTPClient.pas` | `packages/httpclient/source/HTTPClient.pas` | **Diverged** (LWPT ahead) | Four byte-safety fixes — header-recv accumulator + chunked-body seed-buffer cast. Without these, every binary download corrupts at the first `#0` byte. |
| `source/shared/TransportSecurity.pas` | `packages/httpclient/source/TransportSecurity.pas` | Identical | |
| `source/shared/FileUtils.pas` | `packages/httpclient/source/FileUtils.pas` | Identical | |
| `source/shared/StringBuffer.pas` | `packages/httpclient/source/StringBuffer.pas` + `packages/cli/source/StringBuffer.pas` | Identical | Bundled copy in each consuming package per ADR-0014 |
| `source/shared/CLI.Options.pas` | `packages/cli/source/CLI.Options.pas` | **Diverged** (LWPT ahead) | `TGoccia*` prefix stripped from every public type; GocciaScript-engine-specific option groups (`TGocciaEngineOptions` / `TGocciaCoverageOptions` / `TGocciaProfilerOptions` and their enums) removed as dead code |
| `source/shared/CLI.Parser.pas` | `packages/cli/source/CLI.Parser.pas` | **Diverged** (LWPT ahead) | Space-separated option parsing widened from repeatable-only to all string/integer options; `TGoccia` prefix stripped; `AStartArg` parameter added for `lwpt run <subcommand>` aliasing |
| `source/shared/CLI.Help.pas` | `packages/cli/source/CLI.Help.pas` | Diverged (cosmetic) | `TGoccia` prefix stripped; `{$I Goccia.inc}` swapped for `{$I Shared.inc}` |
| `source/units/Goccia.Semver.pas` | `packages/semver/source/Semver.pas` | **Diverged** (LWPT ahead) | Unit renamed; type prefix stripped (`TGocciaSemver*` → `TSemver*`, `EGocciaSemver*` → `ESemver*`); `MAX_SAFE_INTEGER` inlined from the deleted `Goccia.Constants.NumericLimits` dependency |
| `source/units/Goccia.Platform.pas` | `source/Platform.pas` | **Diverged** (LWPT ahead) | Unit renamed; `{$I Goccia.inc}` swapped for `{$I Shared.inc}`. Value vocabulary unchanged (mirrors `Goccia.build.os` etc.) |
| `source/units/Goccia.TOML.pas` | `packages/toml/source/TOML.pas` | **Diverged** (LWPT ahead) | Unit renamed; parser refactored to the class-based AST shape |
| `source/shared/OrderedStringMap.pas` | `packages/toml/source/OrderedStringMap.pas` | Identical | |
| `source/shared/BaseMap.pas` | `packages/toml/source/BaseMap.pas` | Identical | |
| `source/shared/TestingPascalLibrary.pas` | `packages/testing/source/TestingPascalLibrary.pas` | Identical | |
| `source/shared/Shared.inc` | `source/Shared.inc` (+ each `packages/<name>/source/Shared.inc`) | Identical | |

**GocciaScript-only utilities not in LWPT** (will need GocciaScript-side packaging when GocciaScript adopts Path A): `BCP47.pas`, `BOM.pas`, `BigInteger.pas`, `EmbeddedResourceReader.pas`, `HashMap.pas`, `ICU.pas`, `IntlICU.pas`, `IntlLocaleResolver.pas`, `IntlTypes.pas`, `JSONParser.pas`, `MemoryDetection.pas`, `OrderedMap.pas`, `TextSemantics.pas`, `TimeZoneInformationFile.pas`, `TimingUtils.pas`, `UnicodeICU.pas`. These extract into GocciaScript's own `packages/<name>/` tree as part of Path A — LWPT is consumer-agnostic and doesn't dictate their layout.

## Bootstrap chicken-and-egg

LWPT cannot fetch its own deps without HTTPClient existing. The resolution: HTTPClient lives in `packages/httpclient/source/` as part of LWPT's own monorepo, and the bootstrap (`bootstrap.sh` / `bootstrap.bat` / `scripts/bootstrap.pas`) compiles `source/lwpt.pas` directly with `-Fu packages/httpclient/source` alongside every other package's source dir. No separate "slim embedded" copy is needed; the full HTTPClient package is the bootstrap's HTTPClient.

```sh
# Cold bootstrap on a fresh clone (no network needed):
./bootstrap.sh
# → fpc -Mdelphi -Sh ... -Fusource -Fipackages/httpclient/source -Fi... source/lwpt.pas
# → build/lwpt exists; lwpt install + everything else works
```

Once `packages/httpclient/` graduates to its own standalone repo (Phase 2), the chicken-and-egg returns and LWPT will need to keep a bootstrap copy in its repo — either by continuing to maintain `packages/httpclient/` alongside the standalone (slightly wasteful), or by snapshotting the standalone at a fixed commit under `bootstrap/` (more disciplined). The mechanism is a Phase-2 decision that gets its own follow-on ADR at graduation time; today's `packages/httpclient/` setup is correct for the monorepo era.

## Graduation roadmap

Per [ADR-0017](./adr/0017-packages-lwpt-canonical.md), graduation is a **relocation event**: a package leaves LWPT's monorepo for its own standalone repo. The package's content + identity stays the same before and after; only its filesystem location + the consumer's manifest entry change.

### Phase 1: In-monorepo `packages/<name>/` — DONE

The five current packages (`httpclient`, `cli`, `semver`, `toml`, `testing`) have all reached Phase 1. LWPT's root `lwpt.toml` auto-discovers them via `[workspaces] include = ["packages/*"]`. `Platform.pas` and `Shared.inc` are the remaining `source/`-resident extraction candidates; they'd move into `packages/platform/` + a bundled-only `Shared.inc` policy when warranted.

### Phase 2 onwards: Standalone repo

A package leaves LWPT's monorepo for its own standalone repo when warranted by signals like:

- An external (non-`frostney/*`) contributor base develops.
- The package's release cadence diverges meaningfully from LWPT's (e.g. weekly bug fixes while LWPT is monthly).
- The package's CI / docs / tests warrant a dedicated GitHub Actions workflow rather than sharing LWPT's.
- A third-party consumer beyond `frostney/*` materialises.

Any one signal is enough to *consider* graduation; none alone *forces* it. Each graduation gets its own ADR documenting the trigger + the transition plan. After graduation, the LWPT root manifest flips the `[workspaces]` entry for that package to a `[dependencies]` git-host entry (e.g. `httpclient = "frostney/lwpt-httpclient@^1.0.0"`), and LWPT keeps a bootstrap copy if the package is bootstrap-critical (HTTPClient is the only known case today).

## When you modify a package

1. Edit the file at its LWPT-canonical path under `packages/<name>/source/` (or `source/` for `Platform.pas` / `Shared.inc`).
2. **Do not add patch markers.** No `{ [gpm patch] }` / `{ [LWPT patch] }` syntax. The commit message + the inline Pascal comment (explaining *why* the code looks the way it does, when non-obvious) is the record.
3. **Bump the package's version** in `packages/<name>/lwpt.toml`'s `[package].version` per semver 2.0.0 if the change is consumer-visible.
4. **Update tests in the same commit** if a public-surface change. The package's `*.Test.pas` files are the package's own contract; the LWPT-root pre-commit gate (`lwpt format --check` + `lwpt build` + `lwpt test`) catches regressions.
5. **Add an entry to the divergence table above** if the change widens the LWPT-canonical-vs-GocciaScript-older-copy delta. (When GocciaScript adopts Path A and deletes its local copy, the table row gets removed.)

## When a package graduates (in-monorepo → standalone repo)

1. Create the new repo with `packages/<name>/`'s structure as the root (the package's `lwpt.toml` becomes the new repo's root manifest; the `source/` tree moves up).
2. Move the canonical source there (verbatim — the package's identity is unchanged).
3. Update LWPT's root `lwpt.toml`: drop the package from the auto-discovery glob (or add it to the `[workspaces].exclude` list); add a `[dependencies]` entry pointing at the standalone repo (`<package> = "frostney/lwpt-<name>@^X.Y.Z"`).
4. Remove the `packages/<name>/` directory from LWPT's repo, EXCEPT for bootstrap-critical packages where LWPT keeps a copy per the Phase-2 ADR's decision.
5. Write the graduation ADR documenting the trigger + the version pin chosen + the bootstrap-copy decision (if applicable).
6. Mark the row in "the package set" table above as "Graduated to `<repo-url>`".
