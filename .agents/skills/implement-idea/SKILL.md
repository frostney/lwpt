---
name: implement-idea
description: >-
  Turns an unfiled idea into a confirmed mini-spec, implements the selected
  approach, repeats code review and black-box testing, runs the project gate,
  and opens a draft pull request. Use when the user runs /implement-idea or asks
  to build something without an existing issue.
license: Unlicense OR MIT
compatibility: >-
  Requires git and the GitHub CLI (gh) for the /create-pr handoff, plus network
  access. Non-automatic mode also requires registered grilling and render-html
  skills plus Python 3. Verification is driven by the project's
  DEFINITION_OF_DONE.md and declared commands.
---

# Implement idea

Turn the idea into a confirmed mini-spec, then deliver it end to end in the
current repository.

## Gates

- Start with a provisional mini-spec of at most 400 characters, including
  spaces. Confirm the final mini-spec covering the user-visible outcome,
  scope/non-goals, and testable measures of success only after the
  artifact-assisted grill.
- Read project instructions, vision, contribution guidance, Definition of Ready,
  Definition of Done, relevant domain skills, real project commands, affected
  code paths, tests, and related work before deciding.
- Always perform and record web search for current evidence before presenting
  options. Prefer official and primary sources, reconcile them with the versions
  in the checkout, and treat remembered links only as search leads. Stop if the
  search cannot produce current evidence relevant to the decision.
- Outside automatic mode, require the registered `grilling` and `render-html`
  skills plus Python 3. Stop if any dependency is unavailable. Use the actual
  `grilling` decision loop; do not imitate it with ad-hoc questions.
- Before proposing an option, assemble one neutral evidence packet from the
  repository, reproduction, project contracts, current web research, and shared
  current-state artifacts. Derive every option from this same packet.
- Define one comparison rubric from the confirmed outcome, constraints, and
  measures of success before scoring. Give every viable option equivalent
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
- For any code or test change, repeat `/code-review fix-all` and black-box
  testing against the confirmed mini-spec until both pass on the same unchanged
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

1. Draft the provisional mini-spec in at most 400 characters, including spaces.
   Treat it as a starting point, not a confirmed contract.
2. Load the applicable project contracts and specialized skills.
3. Find the existing extension point, reusable patterns, sibling features,
   tests, and architectural constraints. Always perform current web search and
   reconcile its results with the checkout. If the idea already exists,
   recommend using it; if partial, extend rather than duplicate it.
4. Build the neutral evidence packet and comparison rubric, derive the options,
   and validate each with equivalent decision-relevant checks. Compare first;
   recommend only afterward.
5. Outside automatic mode, create a temporary directory outside the worktree.
   Follow the `render-html` schema and render the option comparison there. Open
   the report for review. If inline host preview is unavailable, provide its
   absolute path and continue. Run `grilling` one decision at a time using the
   report and shared evidence, confirm the final mini-spec, then wait for the
   user's choice in chat. Remove the temporary report and its inputs after
   selection unless the user explicitly asks to keep them.
6. After selection, reuse or create a focused branch/worktree and apply the
   `git-workflow` remote-default synchronization gate before editing.
7. Implement the smallest complete change at the correct layer. Update tests and
   docs required by the mini-spec and project contracts.
8. For UI/UX work, render every affected state; capture reviewable before/after
   evidence; check accessibility, responsive behavior, themes, and design-system
   consistency; attach the evidence to the PR.
9. Run targeted checks while developing. Fix failures rather than weakening a
   check.
10. Run `/code-review fix-all` against the measures of success, Definition of
   Done, project conventions, branch diff, and reproducible behavior. Resolve
   every validated in-scope finding. Stop for a material new decision or
   unresolved Blocking or Important finding. If `/code-review` is unavailable,
   perform the same bounded review and fix pass directly.
11. Run `/test-against-spec fix` when it is available. Otherwise perform the
    same black-box test directly: use the confirmed mini-spec, avoid source as
    proof, prefer an exact-revision preview deployment when available, and fall
    back to the local environment. Record each requirement and its observed
    result or limitation.
12. If step 10 or 11 changes the implementation or reports incomplete work,
    continue implementing and restart at step 10. Repeat until code review and
    behavior testing both pass on the same unchanged implementation. Stop and
    ask when required behavior remains unverified after exhausting the available
    environments, unless the user explicitly accepts the limitation or requests
    a draft PR to obtain the missing preview environment.
13. Run the applicable Definition of Done and repository gate. If fixing a gate
    failure changes the implementation, return to step 10. Do not duplicate a
    broad gate inside the behavior-testing step.
14. Use `/create-pr` and pass forward the current mini-spec, delivered outcome,
    and observed completion evidence for the PR.
