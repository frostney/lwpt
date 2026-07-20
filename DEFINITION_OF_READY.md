# Definition of Ready

Use this definition before implementation begins. A requirement may be marked
not applicable only with a recorded reason.

## Ready to investigate

- The desired outcome and user-visible problem are stated.
- Current behavior, scope, non-goals, and known constraints are recorded.
- The proposal is consistent with [`VISION.md`](./VISION.md), or the intended
  Vision change is explicit.
- The applicable contributor instructions and project skills have been read.
- The implementation route is selected:
  - an investigated GitHub issue, normally prepared through
    `/implement-issue`; or
  - a user-confirmed mini-spec, prepared to the same standard through
    `/implement-idea`.

A GitHub issue is the recommended roadmap path, but it is not mandatory for a
user-confirmed implementation idea. `/implement-idea` must not create an
intermediary issue merely to satisfy process.

## Ready to plan

- Current behavior has been traced in source and validated where executable
  source is available; documentation or memory alone is not treated as proof.
- The relevant manifest, lockfile, CLI, filesystem, network, concurrency
  (the thread-safety of runtime-library and libc calls made from
  concurrent threads is verified, not assumed), package-ownership,
  compiler, target, and platform contracts have been considered.
- Existing tests, documentation, ADRs, and nearby implementation patterns have
  been inspected.
- The important design questions have been grilled one decision at a time, and
  the chosen behavior is recorded.
- Acceptance criteria describe observable success and failure behavior.
- Required test tiers and cross-platform checks are identified.
- Dependencies, migration or compatibility expectations, and unresolved
  decisions are explicit.
- If implementation is expected to make or reverse an architectural decision,
  the issue or mini-spec says that the implementation PR requires an ADR. The
  ADR is not written during roadmap planning.

## Ready to edit

- Work starts from freshly fetched remote `main` on a focused feature branch.
- Existing local changes have been inspected and will not be overwritten.
- The selected solution is the smallest complete option that satisfies the
  acceptance criteria and hard constraints.
- Documentation impact and generated-file ownership are known.
- The validation commands needed for completion are known before editing.
