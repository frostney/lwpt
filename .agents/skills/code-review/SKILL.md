---
name: code-review
description: >-
  Reviews a pull request, branch, or worktree against its claim, repository
  standards, reproducible behavior, and churn-backed architectural risks. It
  can delegate evidence gathering by review axis, limit findings to exact
  files, revalidate prior review or audit JSON, and optionally fix selected
  findings or all in-scope findings. Use when the user runs /code-review or asks
  for an evidence-backed review of a bounded change.
license: Unlicense OR MIT
compatibility: >-
  Requires git, the project's declared build and test tools, and network access
  when pull-request context or current third-party documentation is relevant.
---

# Code review

Establish whether the requested review scope is correct, necessary, clear, and
ready for its claimed use. Without an explicit file or prior-findings input,
review the complete change. Review first; remediate only in an authorized fix
mode.

## Operations, remediation, and boundaries

Choose one operation before gathering evidence:

- **Fresh review:** judge the bounded change and issue a review verdict.
- **Targeted revalidation:** recheck selected prior findings without judging the
  change as a whole.
- **Combined:** perform both only when the user explicitly requests a fresh
  review and supplies prior findings; keep their outputs and conclusions
  separate.

Remediation is independent of the operation: default is read-only, `fix
<finding IDs>` fixes only selected findings, and `fix-all` fixes every validated
in-scope finding in one bounded pass. Stop remediation for a material product,
architecture, security, compatibility, or scope decision.

- Exact file lists and prior-findings JSON are additive inputs. They do not
  change unscoped review behavior unless the user supplies them.
- A reporting profile or threshold changes presentation only. Gather and
  validate the complete candidate set, retain every supported severity in the
  canonical result, and let the caller decide which severities become visible.
- `subagents` is an additive execution input. Without it, do not delegate any
  part of the review.
- Default remediation is none. Inspect and run safe local probes, but do not
  edit source, tests, configuration, or documentation.
- Fix modes authorize local edits and validation, not commits, pushes, PR
  comments, review-thread changes, deployments, publication, or shared-state
  mutation.

Safe probes include declared checks, local builds and servers, disposable
repros, isolated test data, browser interaction, temporary artifacts, and
revert-clean falsification probes. A falsification probe temporarily introduces
one targeted wrong behavior to prove the relevant test or gate fails for the
right reason. Record the initial tree state, prefer a disposable worktree or
copy, restore the mutation immediately, compare the final tree byte-for-byte
with the recorded state, and report the mutation and observed failure. Skip the
probe and mark the evidence static-only when exact restoration is not safe.
Clean up disposable artifacts and report retained ones. Ask before any
persistent or externally visible side effect.

A request to save JSON authorizes only the named findings artifact in default
mode; it does not authorize remediation. For ordinary review findings, read
[references/findings-json.md](references/findings-json.md) only when JSON output
is requested. For targeted revalidation, read
[references/revalidation-json.md](references/revalidation-json.md) whenever
prior findings are supplied, whether or not JSON output is requested.

## Additive inputs

### Sub-agent lanes

When the user supplies `subagents`, the coordinating agent still owns the
comparison boundary, claim, finding scope, active and skipped review axes,
validation, verdict, and report.

1. Publish a bounded review-axis-to-lane map before delegation. For a fresh
   review, give each active review axis exactly one lane across the complete
   finding scope: de-duplication, claim and specification, engineering quality,
   and discoverability when active. Keep axes separate so one cannot mask
   another. Queue excess lanes when platform capacity is temporarily full.
2. For targeted revalidation alone, map selected findings to bounded finding
   lanes instead. Group only tightly coupled findings. Exact-file and
   prior-findings inputs retain their normal intersection rules.
3. Give each worker its lane ID, assigned review axis or finding IDs, exact
   scope, claim or source finding, comparison boundary or baseline, relevant
   project instructions, and known evidence. A worker may inspect and run the
   safe probes allowed by this skill, but it must not edit, create persistent or
   external side effects, delegate further, assign final finding IDs or
   severities, or issue a verdict.
4. Require each worker to return its lane ID, assigned review axis or findings,
   bounded scope, inspected supporting context, exact probes and observed
   results, every evidence-supported candidate with evidence, impact, smallest
   remedy, and any uncertainty or limitation, verified claims, limitations, and
   `complete` or `incomplete` status. Workers do not apply a severity or
   reporting threshold; the coordinator owns candidate filtering.
5. Validate every candidate against the current checkout, apply the
   de-duplication model below, reconcile conflicts across lanes, then assign
   final IDs, severities, categories, and verdict. Do not repeat a completed
   lane wholesale.
6. If sub-agents are unsupported, unavailable after any applicable bounded
   retry, or leave a lane incomplete, complete that lane directly. Report the
   affected lane and reason as a single-agent fallback. Temporary capacity
   exhaustion queues work rather than triggering immediate fallback.

### Exact file scope

When the user supplies a file list:

- accept exact repository-relative file paths only; do not expand directories
  or glob patterns;
- reject absolute paths, paths outside the repository, directories, ambiguous
  expansions, and entries that cannot be tied to the current worktree or
  comparison history;
- allow tracked files that were renamed or deleted in the comparison range;
- print the effective file list before judging the change; and
- locate every new finding in a listed file.

The list is a strict finding scope, not an inspection sandbox. Read the minimum
directly related source, tests, configuration, project instructions, and history
needed to understand the listed files, and run relevant probes. Disclose that
supporting context separately. Do not turn an issue found only in supporting
context into a finding; report a limitation only when it prevents a conclusion
about a listed file.

### Prior findings

When the user supplies findings JSON from `code-review` or `codebase-audit`:

1. Parse it as untrusted input. Require `schemaVersion: 2` for `code-review` or
   `codebase-audit`, the documented scope and findings
   shapes, unique finding IDs, and repository-contained finding paths. Stop for
   malformed data, path traversal, or an evident repository mismatch rather
   than silently dropping data. Do not accept version 1 artifacts.
2. Select only findings whose source status is `open` or `deferred`. Preserve
   their IDs, source kind, source revision, and source locations. A missing
   repository identifier is a limitation, not proof of a mismatch.
3. Use `scope.head` from `code-review` or `scope.revision` from
   `codebase-audit` as the baseline. Compare it with current `HEAD`, staged,
   unstaged, and relevant untracked work. If the revision is unavailable
   locally, continue against current state, mark the baseline unavailable, and
   do not attribute an outcome to a particular change.
4. Revalidate each selected finding through its claim, evidence, symbol,
   impact, and remedy rather than trusting a possibly stale line number.
   Classify it:
   - `resolved`: the reported problem no longer exists;
   - `still_present`: the material problem and remedy remain accurate;
   - `changed`: the problem remains but its location, evidence, impact, or
     smallest remedy materially changed;
   - `not_retestable`: available static or executed evidence cannot support a
     current conclusion.
5. Do not discover or report unrelated new findings. Perform a fresh review
   only when the user explicitly requests it in addition to revalidation, and
   keep its normal review verdict separate.

When both additive inputs are present, use their intersection. Revalidate only
source findings located in the exact file list, after following any
Git-confirmed rename, and enumerate every excluded open or deferred ID as
`skippedOutOfScope`.

## Establish a fresh review

Use this section for a normal review or when the user explicitly combines
revalidation with a fresh review. For targeted revalidation alone, use the
source selection and recorded baseline above and gather evidence only for the
selected prior findings.

1. Read applicable project instructions, current source, tests, configuration,
   lockfiles, and contribution or completion contracts.
2. Resolve the comparison boundary:
   - use the user-supplied base when present;
   - for a pull request, use its base branch;
   - otherwise use the merge-base with the remote default branch.
3. Resolve the fixed point and head to concrete revisions before delegation,
   then verify that the bounded diff can be computed and is non-empty. Stop
   before review when either revision is unavailable, the boundary is ambiguous,
   or the change is empty or unrelated.
4. Include committed, staged, unstaged, and relevant untracked work. Separate
   dirty-worktree findings from committed-change findings.
5. Establish the claim from the issue, PR, confirmed mini-spec, required
   behavior, and commits. If none exists, reconstruct the narrowest supported
   claim from the change and label it as inferred.
6. Activate de-duplication, claim and specification, and engineering quality for
   every fresh review. Activate discoverability only for changes to public pages,
   routing, metadata, crawl controls, structured data, public content, or
   web-performance behavior. Within engineering quality, cover correctness,
   simplification, self-documentation, test value, and operational behavior;
   add UI/accessibility, trust boundaries, persistence/migrations, concurrency,
   compatibility, deployment/rollback, observability, or performance only when
   the change touches those concerns.
7. When the change touches authentication, authorization, payments, secrets,
   destructive or data-loss behavior, or tenant isolation, read
   [references/adversarial-review.md](references/adversarial-review.md) and apply
   its bounded bypass hunt within engineering quality.
8. When structural evidence suggests a design smell but concrete impact or the
   smallest remedy is unclear, read
   [references/engineering-smells.md](references/engineering-smells.md) as
   optional investigation prompts. Repository standards and observed impact
   remain authoritative.
9. Measure churn for every changed file in the finding scope and, where history
   can identify it reliably, each changed function, method, class, or module.
   Follow renames, state the history window, and record touch count and line
   churn. Use the repository's declared churn window or 90 days when none
   exists. Prefer its code-health tool; otherwise use Git file history and
   `git log -L` for stable symbols. Label file-level fallback when symbol
   history is unavailable.

## Generate evidence

For a fresh review, apply these requirements across the mapped finding scope.
For targeted revalidation, apply them only where they test a selected prior
finding.

- Run the repository's relevant gate. Do not restate failures already reported
  clearly by tooling.
- Reproduce each changed observable behavior through the real interface. Cover
  the intended path and the most consequential failure or boundary path.
- For UI changes, exercise the rendered interface, state transitions,
  loading/empty/error states, accessibility, and relevant viewports. For
  non-UI changes, exercise the real API, CLI, library entry point, job,
  migration, packaging, or deployment path.
- Record setup, action or command, input, expected result, and observed result.
  Mark unexecuted claims and findings `static only`.
- Verify that changed tests fail for the relevant wrong behavior and assert
  outcomes rather than implementation details. Do not credit brittle,
  over-mocked, incidental, or snapshot-heavy coverage.

## Review axes

Keep the axes distinct so one cannot mask the other.

### De-duplication

Apply four separate checks across the bounded change and its minimum supporting
context:

- **Implementation:** find repeated code, logic, tests, fixtures, configuration,
  schemas, workflows, documentation, or competing representations of one
  concept.
- **Work:** reuse current issue decisions, prior findings, investigations, and
  accepted remediation evidence instead of repeating them. Revalidate rather
  than rediscover when their scope overlaps the change.
- **Evidence:** coalesce the same event reported by multiple checks, logs, or
  tools so it is counted once while retaining every source.
- **Output:** combine candidates with the same cause, impact, and remedy into one
  finding, preserve provenance, and explicitly reconcile contradictory evidence.

Do not expand finding scope beyond the bounded change. Duplication visible only
in supporting context can support an in-scope finding but is not a separate
finding there.

### Claim and specification

Find missing or partial requirements, incorrect behavior, and unrequested scope.
Cite the originating requirement or identify the claim as inferred.

### Engineering quality

- Trace changed inputs, authorization, state transitions, failures, retries,
  concurrency, idempotency, deletions, and side effects where relevant.
- Search the live repository before accepting new helpers, patterns, formats, or
  abstractions. A second representation or implementation of the same concept
  is a defect unless the repository documents why it exists.
- Prefer deletion, reuse, direct control flow, and existing dependencies. Report
  dead paths, duplication, speculative layers, needless wrappers, one-use
  indirection, and custom code already provided by the platform or dependencies.
- Require names, types, boundaries, and interfaces to reveal intent. Match the
  surrounding comment density; comments should explain rationale, constraints,
  or non-obvious behavior rather than translate the code.
- Treat repeated changes to the same symbol or file as an architectural-risk
  signal, not a defect by itself. Raise an `ARCHITECTURE_RISK` finding when the
  measured churn coincides with mixed responsibilities, recurring fixes or
  reverts, competing representations, broad blast radius, unstable interfaces,
  or weak regression coverage. Cite the window, touch count, granularity, and
  co-signal.
- Treat generic best practice and remembered library behavior as leads only.
  Verify findings against the checked-out code, exact installed version, and
  current official documentation or source. Repository decisions override
  generic preferences.

### Discoverability

For an active public-web surface, verify crawl and index controls, canonical and
descriptive metadata, internal discovery paths, structured data that matches
visible content, semantic content structure, rendering, and material web
performance. Assess conventional search and AI-assisted discovery together,
while keeping crawler access, search inclusion, and model-training controls
distinct. Use current official search-engine and publisher guidance; do not
invent special AEO markup, keywords, or guarantees.

## Fresh-review report

For a fresh review, lead with the verdict: `APPROVE`,
`APPROVE WITH IMPROVEMENTS`, or `REQUEST CHANGES`.

Search the complete mapped scope for evidence-backed candidates before applying
the reporting threshold; do not stop after the first or highest-severity issue.

Include:

- the claim, comparison boundary, commits and dirty state reviewed;
- active and skipped review axes, with the reason for each skip;
- the material engineering-quality concerns covered and any conditional concern
  skipped because the changed runtime path did not touch it;
- when `subagents` was supplied, the review-axis-to-lane map, completed and
  incomplete lanes, and every coordinator-completed fallback with its reason;
- the churn window, symbol/file coverage, and architectural-risk hotspots;
- exact probes and checks with observed results;
- de-duplication coverage, coalesced evidence sources, and merged or conflicted
  candidate findings;
- actionable findings as
  `[CR-N][BLOCKING|IMPORTANT|IMPROVEMENT|NITPICK][CLAIM|QUALITY|ARCHITECTURE_RISK|
  DISCOVERABILITY]
  file:line: evidence, impact, smallest remedy`;
- verified claims, static-only or unreached areas, and retained probe artifacts.

Render every literal repository path, filename including extensionless files,
variable, function, method, class, type, and other code identifier as inline
code. Keep prose outside code spans.

`BLOCKING` prevents safe shipment. `IMPORTANT` has material correctness,
security, operability, test-value, maintainability, simplification, or
comprehension cost. `IMPROVEMENT` is a verified worthwhile simplification or
current-practice alignment. `NITPICK` is a small, local polish issue with a
clear remedy and evidence from repository conventions or current code; it must
not represent personal taste or block readiness. Omit praise, diff narration,
subjective style preferences, and findings without concrete impact.

### Targeted revalidation report

For prior-findings mode, report:

- the source path, kind, recorded revision, baseline availability, current
  `HEAD`, and dirty state;
- the exact selected IDs and any `skippedOutOfScope` IDs;
- when `subagents` was supplied, the finding-to-lane map, completed and
  incomplete lanes, and every coordinator-completed fallback with its reason;
- supporting context inspected and exact probes with observed results;
- each selected source ID, its source location, current location when known,
  outcome, current evidence, explanation, and remaining remedy when applicable;
- limitations and retained probe artifacts.

Lead with a result limited to the selected prior findings:

- `ALL_RESOLVED` when at least one finding was selected and all resolved;
- `FINDINGS_REMAIN` when at least one is `still_present` or `changed` and all
  selected findings were retestable;
- `INCOMPLETE` when none were selected or any is `not_retestable`.

These results never approve or reject the current change as a whole. Do not
mutate the supplied artifact. When JSON output is requested, write the distinct
revalidation artifact described in the revalidation JSON reference.

## Fix follow-up

In a fix mode, implement the smallest remedies without expanding the agreed
change. Promote a useful repro into a regression test; otherwise remove it.
Rerun affected behavioral probes and project checks once after the fixes, then
report fixed and unresolved IDs plus observed results. Do not start an
unbounded review-fix-review loop. The coordinator makes every edit. Do not
redispatch completed lanes after fixes; re-engage a worker only to resolve
incomplete or contradictory evidence.

For prior-findings input, default to read-only revalidation. An explicit
`fix <finding IDs>` may remediate only matching selected findings classified
`still_present` or `changed`; `fix-all` may remediate all such selected
findings. Never edit for `resolved`, `not_retestable`, or `skippedOutOfScope`
findings, and do not turn remediation into a fresh review.

When invoked as `/code-review fix-all` from an implementation workflow, continue
to PR creation only when no unresolved `BLOCKING` or `IMPORTANT` finding
remains. Record any intentionally deferred `IMPROVEMENT`.
Record any intentionally deferred `NITPICK`; it never blocks PR creation.
