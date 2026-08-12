---
name: delivery-wait
description: >-
  Provides deterministic, resumable GitHub transition waits used internally by
  delivery workflows. Use when another workflow must await CI, merge, tag, or
  release state without model heartbeats.
license: Unlicense OR MIT
compatibility: >-
  Requires Python 3.11 or newer, the GitHub CLI (gh) authenticated to the target
  repository, and network access.
---

# Delivery wait

Run `scripts/delivery_wait.py` as a silent foreground child whenever a workflow
must await external GitHub state. The harness passively waits for the command to
finish; it must not simulate waiting with model heartbeats.

The caller supplies the repository, expected identity, absolute deadline, and
an optional checkpoint path. The command reconciles any checkpoint with fresh
GitHub state, waits while nothing relevant changes, and exits with one result.
Use `--json` from workflow skills; human output is for direct terminal use.
Skills default checkpoints beneath gitignored `.agent/waits/`; another harness
may supply any private state path.

Use `inspect` for a single authoritative delivery snapshot and `wait` for a
foreground transition wait. Supported predicates are exact-head checks,
pull-request merge, workflow completion, tag target, release assets, and an
absolute wake time. A changed expected head or ref invalidates the wait instead
of being followed silently. GitHub remains authoritative; checkpoints contain
normalized identities and observations, no credentials, raw comment bodies, or
raw API payloads.

The helper uses authenticated `gh` transport. GraphQL is primary. A REST
fallback is used only when GraphQL is rate-limited and REST preserves the same
fact, or when GitHub exposes the fact only through REST.
