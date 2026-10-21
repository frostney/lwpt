---
name: maintain-project-skills
description: >-
  Installs, updates, or migrates project-local skills from their verified
  upstream source while preserving local ownership and pins. Use when asked to
  add, refresh, or migrate a project's local skills.
license: Unlicense OR MIT
---

# Maintain project Agent Skills

Keep project Agent Skills reproducible without turning generated payloads into
hand-authored files. This playbook maintains callers and exceptional migrations;
the reusable workflow owns scheduled refresh mechanics.

Read
[the project-skills maintenance runbook](references/project-skills-runbook.md)
when adding or changing a caller, migrating a deleted or renamed inventory
entry, declaring a skill's role in the generated `AGENTS.md` skills block, or
diagnosing a failed run. It holds the caller shape and permissions,
immutable-pinning rules, migration evidence requirements, role declarations,
and failure branches.

Do not copy the scheduled runtime into a consumer, install KGR globally, edit
CLI-generated payloads or hashes by hand, or merge an automation PR. Use the
consumer's validated project root and pinned skills CLI for every inventory
mutation.

## Completion

- The caller remains thin and pins an immutable reusable-workflow revision.
- `.agents/skills` and `skills-lock.json` changed only through the pinned skills
  CLI or the workflow's opt-in deterministic hash normalization.
- Inventory membership changes have source evidence and were reviewed as a
  migration.
- The caller's workflow validation passes, and any resulting PR remains draft
  for normal project review; nothing was merged automatically.
