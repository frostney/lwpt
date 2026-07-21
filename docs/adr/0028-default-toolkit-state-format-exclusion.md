# Formatter excludes toolkit state by default, with explicit include override

ADR-0007 established manifest-declared format scope as `[package].units` plus
`[format].include`, minus `[format].exclude`. This ADR narrows that rule for
LWPT-owned toolkit state: files under the project-root `.lwpt/` namespace
defined by ADR-0002 — and under any `[lwpt]` `modules-dir` / `archives-dir` /
`tmp-dir` / `cfg-file` override path, which may sit outside `.lwpt/` — are
excluded from `lwpt format` by default, including files contributed by
`[package].units`. A matching explicit `[format].include` opts those files back
in; a matching explicit `[format].exclude` remains the final subtraction and
therefore still wins. The manifest schema does not change. This protects
committed module trees from formatter rewrites that would invalidate frozen
tree hashes while preserving VISION's rule that explicit inputs win. This
decision partially supersedes ADR-0007's claim that the manifest alone defines
the complete set; the exception is limited to LWPT-owned toolkit state and was
investigated in [issue #98](https://github.com/frostney/lwpt/issues/98).

## Considered Options

- **Require every consumer to declare `exclude = [".lwpt/**"]`.** Rejected:
  dependency state is always unsafe to rewrite, and repeated downstream guards
  are evidence that the default places the burden at the wrong layer.
- **Inject `.lwpt/**` as an ordinary exclude.** Rejected because an ordinary
  exclude cannot distinguish the required explicit-include override without
  undoing a user's own explicit exclude.
- **Retain explicit include provenance during scope composition.** Chosen. The
  command resolves includes separately, uses them only to override the built-in
  toolkit-state guard, and applies user excludes afterward.

## Consequences

- A `[package].units` path under `.lwpt/` no longer puts its files in format
  scope by itself.
- `include = [".lwpt/**"]` deliberately opts matching formattable files back in.
- Existing explicit excludes keep their behavior and remain authoritative.
- Consumer manifests may remove boilerplate `exclude = [".lwpt/**"]` entries
  without exposing installed modules to formatter rewrites.
