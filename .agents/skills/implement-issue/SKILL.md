---
name: implement-issue
description: >-
  Validates and implements a GitHub issue against current repository evidence,
  repeats code review and black-box testing, runs the project's completion gate,
  and opens a draft pull request. Use when the user runs /implement-issue with
  an issue number.
license: Unlicense OR MIT
compatibility: >-
  Requires the GitHub CLI (gh) authenticated to the target repository and
  network access. Non-automatic mode also requires registered grilling and
  render-html skills plus Python 3. Verification is driven by the project's
  DEFINITION_OF_DONE.md and declared commands.
---

# Implement issue

Resolve the issue end to end against the current repository, or establish with
evidence that no implementation is needed.

## Gates

- Read the issue, project instructions, vision, contribution guidance,
  Definition of Ready, Definition of Done, relevant domain skills, real project
  commands, affected code paths, tests, and reproduction before deciding.
- Always perform and record web search for current evidence before presenting
  options. Prefer official and primary sources, reconcile them with the versions
  in the checkout, and treat remembered links only as search leads. Stop if the
  search cannot produce current evidence relevant to the decision.
- Outside automatic mode, require the registered `grilling` and `render-html`
  skills plus Python 3. Stop if any dependency is unavailable. Use the actual
  `grilling` decision loop; do not imitate it with ad-hoc questions.
- Before proposing an option, assemble one neutral evidence packet from the
  issue, repository, reproduction, project contracts, current web research, and
  shared current-state artifacts. Derive every option from this same packet.
- Define one comparison rubric from the issue outcome, constraints, and
  requirements before scoring. Give every viable option equivalent
  decision-relevant validation:
  - for UI/UX differences, show each materially different experience;
  - for architecture or workflow differences, show each relevant flow;
  - for interaction-heavy or technical claims, use comparable short-lived
    prototypes or measurements when static evidence cannot decide them.
  Equivalent checks do not require equal implementation effort. Label observed
  facts, proposed behavior, and prototype-only shortcuts.
- If an option reveals an evidence gap, run the same relevant check for every
  affected option. When that is impossible, disclose the unequal evidence and
  reduce confidence before comparison.
- Keep prototypes local and disposable, retain only reviewable captures and
  findings, and remove them when the grill concludes. Do not deploy or publish
  them. Preserve or promote a prototype only with explicit user approval; keep
  approved prototype material outside the selected worktree until its
  `git-workflow` synchronization gate passes.
- Compare two to four genuinely distinct viable options against the declared
  rubric, then recommend one and wait for the user's choice unless automatic
  mode applies. Include a compact evidence digest with the most relevant source
  links, checked project versions, scores, and remaining uncertainty.
- Outside automatic mode, use `render-html` to present that comparison as a
  temporary interactive impact report before the `grilling` decision loop.
  Include shared structured evidence, the declared rubric, option impacts,
  pros, cons, scores, uncertainties, and copyable discussion prompts. Keep the
  recommendation in the closing section after every neutral option.
- When current evidence conclusively fails a required prototype or readiness
  threshold, report that stop without asking whether to bypass the gate.
- For any code or test change, repeat `/code-review fix-all` and black-box
  testing against the issue until both pass on the same unchanged
  implementation, then complete the project gate and `/create-pr`.

## Project definitions

Treat the nearest applicable `DEFINITION_OF_READY.md` and
`DEFINITION_OF_DONE.md` as canonical. If either is absent after a real search,
state that once, carry the gap into the plan and PR, and use only the workflow's
built-in checks plus commands the repository actually declares.

## Automatic mode

Automatic mode applies only when the original prompt says `automatic` or
explicitly requests it. It skips the interactive HTML report and `grilling`
loop, but does not waive any other gate. Do not select an option until the
shared packet, predeclared rubric, and equivalent checks are complete. If a
comparison remains incomplete, report the gap and confidence impact rather
than treating the initial preference as validated. A material product,
architecture, security, scope, or vision decision disables automatic mode.

## Workflow

1. Fetch the issue, including comments and labels; verify it is open,
   implementation-ready, and not a PR, duplicate, blocked, or rejected item.
2. Load the applicable project contracts and specialized skills.
3. Trace the full behavior from entry point to symptom and run the cited
   reproduction or artifact when possible. Search callers, siblings, tests,
   configuration, and history far enough to identify the real layer. Always
   perform current web search and reconcile its results with the checkout.
4. If the behavior no longer reproduces, distinguish:
   - already fixed and covered: recommend closing with the fixing code/commit
     and test evidence;
   - fixed without regression coverage: add the missing test only;
   - shared-root-cause sibling paths still affected: include only those paths.
5. Build the neutral evidence packet and comparison rubric, derive the options,
   and validate each with equivalent decision-relevant checks. Compare first;
   recommend only afterward.
6. Outside automatic mode, create a temporary directory outside the worktree.
   Follow the `render-html` schema and render the option comparison there. Open
   the report for review. If inline host preview is unavailable, provide its
   absolute path and continue. Run `grilling` one decision at a time using the
   report and shared evidence, then wait for the user's choice in chat. Remove
   the temporary report and its inputs after selection unless the user
   explicitly asks to keep them.
7. After selection, reuse or create a focused branch/worktree and apply the
   `git-workflow` remote-default synchronization gate before editing.
8. Implement the smallest complete change at the correct layer. Update tests and
   docs required by the issue and project contracts.
9. For UI/UX work, render every affected state; capture reviewable before/after
   evidence; check accessibility, responsive behavior, themes, and design-system
   consistency; attach the evidence to the PR.
10. Run targeted checks while developing. Fix failures rather than weakening a
   check.
11. Run `/code-review fix-all` against the requirements, Definition of Done,
    project conventions, branch diff, and reproducible behavior. Resolve every
    validated in-scope finding. Stop for a material new decision or unresolved
    Blocking or Important finding. If `/code-review` is unavailable, perform
    the same bounded review and fix pass directly.
12. Run `/test-against-spec fix` when it is available. Otherwise perform the
    same black-box test directly: use explicit issue requirements, avoid source
    as proof, prefer an exact-revision preview deployment when available, and
    fall back to the local environment. Record each requirement and its observed
    result or limitation.
13. If step 11 or 12 changes the implementation or reports incomplete work,
    continue implementing and restart at step 11. Repeat until code review and
    behavior testing both pass on the same unchanged implementation. Stop and
    ask when required behavior remains unverified after exhausting the available
    environments, unless the user explicitly accepts the limitation or requests
    a draft PR to obtain the missing preview environment.
14. Run the applicable Definition of Done and repository gate. If fixing a gate
    failure changes the implementation, return to step 11. Do not duplicate a
    broad gate inside the behavior-testing step.
15. Use `/create-pr`, include `Closes #<issue>`, pass forward the current
    completion evidence, and report only observed results.
