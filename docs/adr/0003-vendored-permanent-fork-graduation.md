# Vendored code is a permanent fork, with a graduation roadmap to standalone LWPT-managed packages

> **Superseded by [ADR-0017](./0017-packages-lwpt-canonical.md).** The "vendored from GocciaScript upstream + permanent fork + courtesy patches" framing this ADR established was wrong: **LWPT and GocciaScript are sister projects under the same owner**, not upstream/downstream. LWPT's `packages/<name>/` is the **canonical source** for HTTPClient, CLI, Semver, TOML, TestingPascalLibrary, TransportSecurity, FileUtils, StringBuffer, Platform, OrderedStringMap, BaseMap, and `Shared.inc`; GocciaScript is the first named consumer, committed to Path A adoption (full toolchain migration to `lwpt build / install / test / format`). ADR-0017 owns the canonical-source story end-to-end, including the divergence policy (freeze GocciaScript's copies during the transition), the AGENTS.md Hard Constraint rewrite ("Packages own their contents"; "No patch markers"), and the patch-marker sweep (rewriting each `{ [gpm patch] }` / `{ [LWPT patch] }` comment as a plain Pascal comment preserving the rationale).
>
> This ADR stays in the repo as historical record of the upstream-fork framing that was tried, didn't survive contact with the actual ownership model, and got corrected in a later cycle. The "no `vendored.toml` / no drift-check infrastructure" decision survives under the new framing (with packages canonical-at-LWPT, there's nothing external to drift against); the "graduation arc" survives reframed as a relocation event rather than a state transition of identity.

---

## Original framing (historical — superseded)

LWPT vendors ten units from GocciaScript (CLI.Parser/Options/Help, Semver, HTTPClient, TransportSecurity, FileUtils, StringBuffer, TestingPascalLibrary, plus `Shared.inc`). Most stay verbatim. Two named exceptions — the `CLI` namespace and `Semver` — carry consistent `[LWPT patch]` markers because they're being prepared for post-v1 graduation as standalone packages (prefix-strip + dead-code removal in CLI; rename + inline of one constant in Semver). Other vendored files also carry markers where applicable: `[gpm patch]` in `HTTPClient.pas` (byte-safety fixes for binary downloads) and `[LWPT patch]` in `CLI.Parser.pas` (parser widening). We treat the vendored copies as a **permanent fork**: patches stay forever, no `vendored.toml` / `verify-vendor.pas` drift-checking infrastructure, no commitment to follow GocciaScript upstream. Patches will be **submitted upstream as a courtesy**, never as a dependency of the LWPT roadmap. Post-v1, several vendored units **graduate** into their own standalone LWPT-managed Pascal packages: HTTPClient first (it's foundational and self-contained), CLI second, and probably Goccia.Semver and TestingPascalLibrary later. Other Pascal projects consume the graduated packages via their own `lwpt.toml`; LWPT itself keeps a slim bootstrap copy of HTTPClient indefinitely to break the chicken-and-egg ("LWPT needs HTTPS to fetch its own dependencies").

## Amendment (per ADR-0015) — TestingPascalLibrary graduated early

The roadmap when this ADR was written listed `TestingPascalLibrary` as a *late* graduation candidate (after HTTPClient/CLI/Semver). [ADR-0015](./0015-drop-export-testing-becomes-workspace-package.md) pulled that forward: with `lwpt export` removed and the embedded-blob model dropped, TestingPascalLibrary moved into `packages/testing/` as the fifth workspace package alongside `httpclient`, `cli`, `semver`, `toml` in the same wave that deleted the export plumbing. Phase 1 (in-repo `packages/<name>/`) is now complete for five units; Phase 2 (graduate to a standalone repo + consume via git-host dep) is on the same arc for all five. The remaining Phase 3 candidate is `Platform.pas` only.

## Considered Options

- **Track upstream + drift-check infrastructure.** Open PRs, pin upstream commits in `vendored.toml`, run a `verify-vendor.pas` script in CI that diffs against pinned upstream modulo patch regions, bump when upstream releases the fix. Rejected because (a) we already differ from upstream meaningfully, (b) the coordination cost is permanent ceremony, and (c) the graduation plan replaces "upstream" with "our own controlled package" anyway.
- **Consume GocciaScript as a Pascal package via lwpt itself.** Chicken-and-egg: lwpt needs HTTPClient to install its dependencies, including GocciaScript. Rejected on its face.
- **Pure permanent fork with no graduation plan.** Acceptable, but loses the option for other Pascal projects to consume HTTPClient/CLI as first-class packages — and they're genuinely good standalone libraries. The graduation plan unlocks ecosystem value.

## Consequences

- HTTPClient is maintained in two places once graduated: the slim bootstrap copy inside LWPT, and the full standalone package. Acceptable as long as the slim copy stays minimal (HTTPS GET + sha256 verification — nothing else) and is syncs from the standalone package's authoritative version.
- GocciaScript upstream may eventually accept the patches we submit, may not. Either is fine — our roadmap doesn't depend on it.
- A future reader sees HTTPClient vendored inside LWPT *and* an HTTPClient LWPT-package and wonders why. This ADR is the answer. Link to it from `docs/vendored.md`.
