# Milestone Rush event ledger

Append one valid JSON object per line to ignored
`.agent/milestone-rush-events.jsonl`. This runtime artifact is append-only and
must never be staged or committed. Preserve earlier runs and distinguish them by
stable `runId`.

## Event envelope

Every event contains:

```json
{
  "schemaVersion": 1,
  "runId": "stable run ID",
  "eventId": "stable event ID",
  "type": "transition type",
  "timestamp": "RFC 3339 timestamp",
  "spanId": "stable span ID or null",
  "spanKind": "span category or null",
  "parentSpanId": "stable span ID or null",
  "blockingSpanIds": [],
  "identity": {
    "laneId": null,
    "decisionId": null,
    "issue": null,
    "pullRequest": null,
    "branch": null,
    "head": null
  },
  "actor": {"kind": "coordinator | worker | watcher | tool | user", "capabilityClass": null},
  "context": {"mode": "isolated | recent-slice | full-history | coordinator", "exceptionDecisionId": null},
  "result": "started | succeeded | failed | pending | blocked | cancelled | unavailable",
  "blocker": null,
  "retryAt": null,
  "usage": {
    "inferences": null,
    "inputTokens": null,
    "cachedInputTokens": null,
    "uncachedInputTokens": null,
    "outputTokens": null,
    "reasoningTokens": null,
    "compactions": null,
    "unavailableFields": []
  },
  "resources": {
    "runnerMilliseconds": null,
    "agentMilliseconds": null,
    "toolCalls": null,
    "commandMilliseconds": null,
    "effectiveWorkers": null,
    "unavailableFields": []
  }
}
```

Use explicit `span_started` and `span_finished` events with the same `spanId` and
a `spanKind` for worker activity, coordinator work, local command or gate, CI,
review, cooldown, decision wait, remediation, rework, restack, merge, and genuine
idle time. Add stable blocking relationships so later analysis can distinguish
critical-path, overlapping, and masked work.

Record run, worker, gate, push, CI, review, wait, retry, remediation, restack,
merge, rework, and run lifecycle transitions. Record `decision_requested` and
`decision_resolved` with the same stable decision ID, exact timestamps, actor,
and outcome. Record policy-threshold crossings and the resulting checkpoint and
intervention.

Use host-reported inference, token, cache, reasoning, and compaction values only.
Leave unavailable values `null` and enumerate their field names; never estimate
usage. Keep elapsed wall time separate from aggregate runner time, concurrent
agent time, tool calls, inferences, and tokens. Overlapping spans may make
aggregate consumption exceed elapsed time and must never be summed as delivery
lead time.

## Closure validation

Before milestone closure, validate every event for the current `runId`:

- stable event IDs are unique and every required envelope field is present;
- every started span has exactly one terminal finish with matching identity;
- run, lane, command/local-gate, CI, review, wait/watcher, remediation, merge,
  and decision transitions that occurred are represented;
- command spans record elapsed milliseconds and effective worker capacity when
  exposed by the command; CI spans name workflow/run/job IDs and runner time
  when the forge exposes them;
- usage and resource values exposed by the host are recorded, while every null
  value is named in the matching `unavailableFields` array; and
- superseded local or CI work ends as `cancelled` or has an explicit blocker
  explaining why safe cancellation was unavailable.

Missing transitions, unclosed spans, duplicate IDs, and silent nulls are invalid
ledger evidence and block milestone closure. Zero is a measured value; it is
never a substitute for unavailable.
