"""Pure managed-delivery state helpers.

The workflow adapters deliberately keep GitHub I/O outside this module so the
state transitions can be exercised with deterministic fixtures.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from typing import Any, Iterable


MANAGED_LABEL = "delivery:managed"
CI_READY_LABEL = "ci:ready"
REVIEW_READY_LABEL = "review:ready"
MERGE_READY_LABEL = "merge:ready"
FULL_CI_REQUIRED_LABEL = "ci:full-required"
READINESS_LABELS = (CI_READY_LABEL, REVIEW_READY_LABEL, MERGE_READY_LABEL)


class DeliveryError(RuntimeError):
    """A fail-closed transition or evidence error."""


def label_names(pull_request: dict[str, Any]) -> set[str]:
    labels = pull_request.get("labels", [])
    if isinstance(labels, dict):
        labels = labels.get("nodes", [])
    return {label["name"] for label in labels if label and "name" in label}


def require_expected_head(pull_request: dict[str, Any], expected_head: str) -> None:
    actual = pull_request.get("head", {}).get("sha") or pull_request.get("headRefOid")
    if not expected_head or actual != expected_head:
        raise DeliveryError(
            f"stale head: expected {expected_head or '<missing>'}, current {actual or '<missing>'}"
        )


def derive_candidate_snapshot(pull_request: dict[str, Any]) -> dict[str, Any]:
    """Return the exact singleton or native bottom-through-candidate prefix."""

    candidate = {
        "number": pull_request["number"],
        "head": pull_request["headRefOid"],
        "base": pull_request["baseRefOid"],
        "base_ref": pull_request["baseRefName"],
        "full_ci_required": FULL_CI_REQUIRED_LABEL in label_names(pull_request),
    }
    stack = pull_request.get("stack")
    if stack is None:
        return {"mode": "singleton", "candidate": pull_request["number"], "entries": [candidate]}

    stack_entry = pull_request.get("stackEntry")
    if not stack_entry:
        raise DeliveryError("native stack has no candidate stack entry")
    candidate_position = stack_entry["position"]
    raw_entries = stack.get("entries", {}).get("nodes", [])
    entries: list[dict[str, Any]] = []
    for raw in sorted(raw_entries, key=lambda item: item["position"]):
        if raw["position"] > candidate_position:
            continue
        member = raw.get("pullRequest")
        if not member:
            raise DeliveryError(f"native stack position {raw['position']} has no pull request")
        entries.append(
            {
                "position": raw["position"],
                "number": member["number"],
                "head": member["headRefOid"],
                "base": member["baseRefOid"],
                "base_ref": member["baseRefName"],
                "full_ci_required": FULL_CI_REQUIRED_LABEL in label_names(member),
            }
        )

    expected_positions = list(range(1, candidate_position + 1))
    actual_positions = [entry["position"] for entry in entries]
    if actual_positions != expected_positions:
        raise DeliveryError(
            f"native prefix is not contiguous: expected {expected_positions}, got {actual_positions}"
        )
    if not entries or entries[-1]["number"] != pull_request["number"]:
        raise DeliveryError("candidate is not the top of its derived native prefix")

    return {
        "mode": "native-prefix",
        "candidate": pull_request["number"],
        "stack_id": stack["id"],
        "stack_number": stack["number"],
        "stack_base_ref": stack["baseRefName"],
        "entries": entries,
    }


def snapshot_digest(snapshot: dict[str, Any]) -> str:
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def snapshot_requires_full_ci(snapshot: dict[str, Any]) -> bool:
    return any(entry["full_ci_required"] for entry in snapshot["entries"])


def snapshot_contains(snapshot: dict[str, Any], pull_request_number: int) -> bool:
    return any(entry["number"] == pull_request_number for entry in snapshot["entries"])


def workflow_conclusion(conclusion: str | None) -> tuple[str, str]:
    if conclusion == "success":
        return "success", "Workflow completed successfully"
    return "failure", f"Workflow concluded {conclusion or 'without a terminal result'}"


def watchdog_expired(started_at: str, maximum_age_minutes: int, now: datetime) -> bool:
    started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    return (now - started).total_seconds() >= maximum_age_minutes * 60


def review_evidence_errors(
    head_sha: str,
    automations: Iterable[dict[str, Any]],
    checks: Iterable[dict[str, Any]],
    reviews: Iterable[dict[str, Any]],
    threads: Iterable[dict[str, Any]],
    maintainer_logins: set[str],
) -> list[str]:
    """Evaluate provider-neutral terminal-review and thread evidence."""

    errors: list[str] = []
    automation_list = list(automations)
    check_list = list(checks)
    review_list = list(reviews)
    thread_list = list(threads)

    for automation in automation_list:
        automation_id = automation["id"]
        actors = set(automation["actors"])
        context = automation.get("check_context")
        if context:
            matching_checks = [check for check in check_list if check.get("name") == context]
            latest_check = max(matching_checks, key=lambda item: item.get("id", 0), default=None)
            if not latest_check or latest_check.get("conclusion") != "success":
                errors.append(f"{automation_id}: terminal successful check is missing")

        terminal_states = set(automation.get("terminal_review_states", ["APPROVED", "COMMENTED"]))
        terminal_reviews = [
            review
            for review in review_list
            if review.get("author", {}).get("login") in actors
            and review.get("commit", {}).get("oid") == head_sha
            and review.get("state") in terminal_states
        ]
        if not terminal_reviews:
            errors.append(f"{automation_id}: terminal current-head review is missing")

    for index, thread in enumerate(thread_list, start=1):
        comments = thread.get("comments", [])
        automation_indexes = [
            comment_index
            for comment_index, comment in enumerate(comments)
            if any(
                comment.get("author", {}).get("login") in set(item["actors"])
                for item in automation_list
            )
        ]
        if thread.get("isResolved") is not True:
            errors.append(f"thread {index}: unresolved")
        if automation_indexes:
            first_automation = min(automation_indexes)
            replied = any(
                comment_index > first_automation
                and comment.get("author", {}).get("login") in maintainer_logins
                for comment_index, comment in enumerate(comments)
            )
            if not replied:
                errors.append(f"thread {index}: no current maintainer reply")

    return errors
