# Repository Orchestration Policy

LWPT's agent-orchestration policy, subordinate to [`AGENTS.md`](./AGENTS.md)
and repository security policy. The known-good-route skills own delivery:
`/deliver` publishes, merges, and verifies integration; `/address-feedback`
converges review; `delivery-wait` awaits GitHub state; milestone-rush fans out
work. This file declares only what those skills need from LWPT
([ADR-0046](./docs/adr/0046-skill-owned-delivery.md)).

## Capability classes and routing

Use host-neutral capability classes, never product model names.

- **Efficient** (standard reasoning): monitoring, status collection,
  deterministic checks, and mechanical evidence extraction.
- **Frontier** (high reasoning): design, implementation, security work, complex
  diagnosis, and independent review.

Split mixed work so the material decision stays frontier. If classification is
ambiguous, use frontier and record why. No intervention may silently downgrade
work below the class this routing requires.

## Context packets

Workers start with no inherited conversation history. A packet carries the
applicable decision IDs and their settled text, issue or PR identity, branch
and exact head, owned scope, dependencies, acceptance criteria, required gates,
capability class, and the structured result expected back. Add the three to
five most recent turns only when they are immediately relevant. Full-history
inheritance needs a recorded, scoped exception.

## Token checkpoints and interventions

Context occupancy is one inference's input tokens divided by the active
context window. Track the rolling median over the lane's latest ten inferences.

- Median greater than 40%: record a warning and choose to continue,
  checkpoint, split, replace, or escalate.
- Median greater than 55%: checkpoint durable state, then split or replace the
  lane before another inference.
- 25th consecutive inference without a durable transition (a settled decision,
  a new exact head, or a validation, review, PR, or merge state change): record
  and carry out a continue, split, replace, or escalate decision before
  inference 26.

An intervention never silently stops required work or downgrades capability.

## Monitoring and waits

Await GitHub state with `delivery-wait` or address-feedback's `review_wait.py`,
never with model heartbeats. A monitor makes at most three inferences without
an external state change, then hands the wait to a non-LLM command. Time-based
wakes use the exact reported timestamp.

## Escalation

Escalate to the maintainer for a material product or architecture decision,
missing authority, new infrastructure or spending, or policy that is malformed
or contradictory. Name the exact rule and evidence, keep the durable work, and
do not spawn lanes under guessed semantics.

## Lane-admission preflight

FPC 3.2.2 silently truncates paths longer than 255 characters in compiler
staging, linking, and gzip archive opens
([#309](https://github.com/frostney/lwpt/issues/309)). Before adopting or
creating a worktree, run this from its root; it must succeed:

```sh
test "$(pwd -P | tr -d '\n' | wc -c)" -le 64
```

Evidence: a traced `./build/lwpt test --no-cache` of `917c174` gunzipped an
archive 187 characters below the root (`InstallGitGraph.Test.pas`) and
compiled into staging 186 characters below it (`TestCache.Test.pas`). The
255-character limit leaves 68; 64 keeps room for wider process IDs in
temporary names. `BuildSessions.Test.pas` builds an over-limit path on purpose
and does not count. Relocate a longer candidate to a shorter path before
implementation or a local gate; never learn this limit from failing tests.

## Integration and merge

- **Destination:** `main`. A delivery is integrated when the push run of
  `ci.yml` on its squash commit concludes green.
- **Required check:** `delivery-admission` from `pr.yml` on the exact head,
  with every review thread resolved. Merge a single PR with
  `gh pr merge --squash --match-head-commit <sha>`; a native stack merges
  through `git-workflow`.
- **Full CI:** a PR labelled `ci:full-required` also needs a green
  `gh workflow run ci.yml --ref <branch> -f mode=manual` run whose head is the
  PR's exact head. Await it with `delivery-wait wait workflow-terminal`, then
  merge with `--match-head-commit <sha>`. A new head needs a new run.
- **Review policy:** `.github/delivery/review-automations.json`.
- **Diagnostics** (`-f mode=diagnostic`) are remediation, never proof.
