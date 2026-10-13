# LWPT builds LWPT (self-host) with a one-time bootstrap script

LWPT's own build system is `lwpt build` — the same subcommand any other Pascal project on this stack uses. The repository's `lwpt.toml` lists `lwpt` as a `[targets]` entry; `./build/lwpt build` recompiles itself, `./build/lwpt test` runs its own self-test suite, `./build/lwpt format --check` enforces its own style. The chicken-and-egg is resolved by `scripts/bootstrap.pas` (InstantFPC, invoked via `bootstrap.sh` / `bootstrap.bat` on Windows) — a one-time fresh-clone step that runs a single `fpc` invocation against `source/lwpt.pas` to produce the first `build/lwpt` binary. After bootstrap, every subsequent operation is `./build/lwpt <subcommand>`. The reason is that dogfooding LWPT on LWPT validates the build pipeline on every CI run, removes a divergence surface between an external build wrapper and `lwpt build` code, and is consistent with the graduation roadmap (ADR-0003): the standalone packages we extract post-v1 will use LWPT as their build system from day one, so LWPT itself ought to as well.

## Considered Options

- **External `build.pas` program** compiled to `build/build` (the GocciaScript pattern that lwpt's build logic was originally lifted from). Doubles the maintenance surface — every change to LWPT's build behavior happens in two places. Rejected.
- **Makefile / Justfile.** The `project-structure` rule allows these as a fallback when the project's primary language is too heavy for the build step. Doesn't apply here: LWPT is a Pascal toolkit whose entire purpose is to be the build step for Pascal projects. Using Make would be self-undermining.
- **Commit pre-built `lwpt` binaries per platform** so no bootstrap is needed. Repo bloat, trust questions ("who reviewed the binary?"), breaks build reproducibility. Rejected.
- **Extract build logic into a unit usable from both `build.pas` and lwpt itself.** Cleaner than the standalone-`build.pas` alternative but still maintains two entry points the build pipeline can use, with the inevitable drift between them. Rejected for the same dogfood-loss reason.

## Consequences

- The bootstrap script's `fpc` flags must stay in sync with the flags `lwpt build` itself uses. We share them via `scripts/bootstrap-flags.inc` (or equivalent shared constant) imported from both sites.
- `./build/lwpt build --clean lwpt` on Windows would delete the binary that's currently executing — file-lock conflict. Special-case: the current-executable target skips the delete step and recompiles in-place.
- A contributor without `instantfpc` in their `PATH` can't run `scripts/bootstrap.pas` directly. The shell wrappers (`bootstrap.sh`, `bootstrap.bat`) handle the InstantFPC discovery + fallback to a direct `fpc` invocation.
- New contributors hit "lwpt: command not found" if they haven't bootstrapped. `docs/quick-start.md` documents the bootstrap step prominently; the pre-commit hook can chain `[ -x ./build/lwpt ] || ./bootstrap.sh` as a safety net.
