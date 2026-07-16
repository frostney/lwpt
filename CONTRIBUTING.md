# Contributing to LWPT

This file is the authoritative contract for human contributors. AI assistants follow [`AGENTS.md`](./AGENTS.md), which carries the same Hard Constraints; nothing should live in both files — pick the right home and link from the other.

## Before you start

- Read [`AGENTS.md`](./AGENTS.md). The "Hard Constraints" section enumerates the rules a PR may not violate; the rest of the file is the operating manual for the toolkit.
- Skim the ADRs in [`docs/adr/`](./docs/adr/) — six short notes covering the decisions that shape the current shape of the code. If your change challenges one of these, raise it before writing code.
- Make sure your environment matches [`docs/tooling.md`](./docs/tooling.md): FPC 3.2.2 (verified live, never assumed), InstantFPC (bundled with FPC), Lefthook for the pre-commit hook.

## Setup

[`docs/quick-start.md`](./docs/quick-start.md) is the canonical setup walkthrough. Short version:

```sh
./bootstrap.sh                  # one-time per fresh clone
./build/lwpt format --check     # verify your environment
./build/lwpt build              # self-host build
./build/lwpt test               # run the self-test suite
```

Install Lefthook hooks once: `lefthook install`.

## Pull request gate

The pre-commit hook runs `lwpt format` locally (with `stage_fixed: true`, so any rewrites are auto-staged into the same commit). The heavyweight gates — `lwpt format --check`, `lwpt build`, `lwpt test` — run on the PR workflow in CI. A PR is mergeable when:

1. All three pre-commit commands exit zero on the proposed branch.
2. CI is green on every Tier 1 platform from [`docs/deployment.md`](./docs/deployment.md).
3. The change has tests where tests are the right answer (see [`docs/testing.md`](./docs/testing.md) for the policy on when each test tier applies).
4. Documentation that mentions the changed surface has been updated. The no-duplication rule from [`docs/`](./docs/) applies: edit the *one* canonical document, not five.

If any check fails on a hook autofix you didn't expect, do not commit with `--no-verify`. Investigate, then fix.

## Commit messages

Use [conventional commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `build:`, `ci:`, `style:`, `revert:`). Release preparation uses the committed `cliff.toml` to preview the unreleased changelog without writing `CHANGELOG.md`; `/create-release` performs the later generation step. Clear commit messages determine the published categorization.

## When to write an ADR

[`docs/adr/`](./docs/adr/) records decisions, not designs. Add an ADR when **all three** are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful.
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons.

If any are missing, skip it. Most PRs do not produce an ADR. Format is in `.agents/skills/grill-with-docs/ADR-FORMAT.md` (or the inline pattern in the existing ADRs — one paragraph plus optional sections).

## Workspace packages

LWPT ships five workspace packages under `packages/<name>/` — `httpclient`, `cli`, `semver`, `toml`, `testing`. Each is a standalone Object Pascal project (own `lwpt.toml`, own `source/`, own tests, own version). Per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md), **LWPT is the canonical source** for every package (no upstream to defer to; GocciaScript is a sister project committed to Path A adoption, not an authority).

The Hard Constraint is **"Packages own their contents"** — the root LWPT manifest discovers each package via `[workspaces]` and consumes its published API; each package owns its versioning, lifecycle hooks, test policy, and public surface. **Format scope follows the root-owns-by-default rule**: the root's `[format]` walks workspace packages too (the LWPT root's `[format].include` covers `packages/**/*.pas` + `packages/**/*.inc`), and a package can opt out by declaring its own `[format]` section in `packages/<name>/lwpt.toml`.

If you need to change a package:

1. Edit the file at its canonical path under `packages/<name>/source/`.
2. **Do not add patch markers.** No `{ [gpm patch] }` / `{ [LWPT patch] }` syntax. Git history is the canonical record; inline Pascal comments explain non-obvious *why*.
3. Bump the package's `[package].version` in its `lwpt.toml` per semver 2.0.0 if the change is consumer-visible.
4. Update the package's own `*.Test.pas` files in the same change if the public surface shifts.
5. If the change widens the LWPT-canonical-vs-GocciaScript-older-copy delta, add a row to the divergence table in [`docs/packages.md`](./docs/packages.md).

Per the graduation roadmap in ADR-0017, individual packages will graduate to standalone repos when warranted. If your change touches HTTPClient or CLI substantially, mention the graduation context in the PR description.

## Planned work

[`VISION.md`](./VISION.md) owns product direction; GitHub issues and milestones own planned scope and scheduling. Coordinate work on the [registry](https://github.com/frostney/lwpt/issues/29), [link checking](https://github.com/frostney/lwpt/issues/31), [duplication](https://github.com/frostney/lwpt/issues/32), or [codebase health](https://github.com/frostney/lwpt/issues/33) through those issues rather than a drive-by PR. [`DEFINITION_OF_DONE.md`](./DEFINITION_OF_DONE.md) owns the project-local release and architecture-conformance gate.

## Reporting issues

A good issue includes: the LWPT version (`./build/lwpt --version`), the host platform (`uname -a`, `fpc -iV`), the manifest snippet (if relevant), and the exact command + observed output. For crashes mid-install, run `./build/lwpt repair` first and report whether the recovery worked.
