# `.lwpt/` namespace, zero-install by default, Z-both (modules + archives committed)

Per-project dependency state lives under `.lwpt/` at the project root: `.lwpt/modules/<dep>/` holds extracted dependency trees (committed; this is what FPC's `-Fu` paths point at), `.lwpt/archives/<dep>-<ver>-<sha256>.tar.gz` holds the source-of-truth tarballs (committed; used for hash-verification on `lwpt install --frozen`), and `.lwpt/tmp/` is the gitignored install workspace where atomic-rename operations stage their work. There is no global content-addressable cache in v1 — every project is self-contained on disk, so `git clone && fpc @lwpt.cfg` builds the project without running `lwpt install`. The reason is that this gives us true zero-install in the Yarn-PnP / `cargo vendor` sense (a fresh clone is buildable), idempotent operations (`rm -rf .lwpt/tmp/ && lwpt install` is always safe), double verification on `--frozen` (both the archive hash and the extracted-tree hash are checked against the lockfile), and a clean separation between toolkit state and project source that no other Pascal package manager currently provides.

## Considered Options

- **Z-pure (extracted trees only, no archives committed).** Smallest committed footprint, but loses the archive-hash verification path and removes the ability to re-extract from a known-good source if a contributor accidentally edits a file under `.lwpt/modules/`. Rejected via owner pushback in Q1c.
- **Z-archive (archives only, lazy extract on first build).** Smaller repo, but `fpc @lwpt.cfg` can't run standalone after clone — defeats true zero-install.
- **Global content-addressable cache** (pnpm `~/.pnpm-store/` style). Saves disk across projects. Rejected for v1 because (a) it adds machine state that breaks "the project is self-contained on disk", (b) the Pascal package ecosystem isn't yet at the scale where cross-project dedup pays off, and (c) opt-in global cache can be added later under its own ADR without breaking the on-disk shape.
- **`vendor/`** (no prefix, FreePascal/Delphi historical convention). Collides with hand-vendored content; ambiguous ownership; no scoping for archives + tmp + future subdirs.
- **`lwpt_modules/`** (npm-style, project-prefixed). Considered seriously. Rejected in favor of `.lwpt/` because the hidden namespace cleanly groups `modules/` + `archives/` + `tmp/` (and any future toolkit state) under one root, and the npm-aesthetic concern is real enough to warrant the cleaner shape.

## Consequences

- Repo size grows with dependency count. Pascal libraries are small (tens of `.pas` files, not the thousands a typical npm package ships), so this is bounded.
- Dependency upgrades produce per-file git diffs — louder than committing a zip would be, but reviewable. Treat this as a feature: the next reviewer can see exactly what changed in an upgrade.
- Cross-filesystem rename failures (EXDEV) need a copy-then-delete fallback (documented in `docs/tooling.md`).
- Adding an opt-in global cache later means new behavior, not a change to the on-disk shape — backwards compatible.
