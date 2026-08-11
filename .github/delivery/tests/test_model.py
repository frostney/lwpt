from __future__ import annotations

import argparse
import copy
import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


DELIVERY_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DELIVERY_DIR))

from controller import Controller, MANAGED_RUN_RE, positive_integer  # noqa: E402
from model import (  # noqa: E402
    DeliveryError,
    derive_candidate_snapshot,
    require_expected_head,
    review_evidence_errors,
    snapshot_digest,
    snapshot_requires_full_ci,
    watchdog_expired,
    workflow_conclusion,
)


FIXTURES = Path(__file__).with_name("fixtures")


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class FakeGitHub:
    repository = "frostney/lwpt"


class FakeCheckGitHub(FakeGitHub):
    def __init__(self, check: dict) -> None:
        self.check = check
        self.updated: list[tuple[int, dict]] = []

    def check_run(self, check_id: int) -> dict:
        return self.check

    def check_runs(self, head: str) -> list[dict]:
        return [self.check]

    def update_check(self, check_id: int, **fields: object) -> None:
        self.updated.append((check_id, fields))


class FailingDispatchGitHub(FakeCheckGitHub):
    def dispatch(self, workflow: str, inputs: dict[str, str]) -> None:
        raise DeliveryError(f"dispatch of {workflow} was refused")


class DeliveryModelTests(unittest.TestCase):
    def test_exact_head_accepts_only_current_sha(self) -> None:
        pull = {"head": {"sha": "a" * 40}}
        require_expected_head(pull, "a" * 40)
        with self.assertRaisesRegex(DeliveryError, "stale head"):
            require_expected_head(pull, "b" * 40)

    def test_duplicate_delivery_uses_one_deterministic_key(self) -> None:
        controller = Controller(FakeGitHub())
        key_one = controller.delivery_external_id(41, "1" * 40, "a" * 64)
        key_two = controller.delivery_external_id(41, "1" * 40, "a" * 64)
        self.assertEqual(key_one, key_two)

    def test_finalizer_run_identity_binds_topology_and_check(self) -> None:
        title = f"delivery-pr/41/{'1' * 40}/{'a' * 64}/99"
        match = MANAGED_RUN_RE.match(title)
        self.assertIsNotNone(match)
        self.assertEqual(("41", "1" * 40, "a" * 64, "99"), match.groups())

    def test_finalizer_rejects_an_unowned_check_id(self) -> None:
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "delivery-admission",
                "app": {"slug": "some-other-app"},
                "external_id": f"delivery:v1:41:{'1' * 40}:{'a' * 64}",
            }
        )
        controller = Controller(github)
        with self.assertRaisesRegex(DeliveryError, "not the expected app-owned"):
            controller.require_owned_check(
                99,
                "delivery-admission",
                f"delivery:v1:41:{'1' * 40}:{'a' * 64}",
            )
        self.assertEqual([], github.updated)

    def test_dispatch_failure_terminally_fails_the_owned_proof(self) -> None:
        github = FailingDispatchGitHub({"id": 99})
        controller = Controller(github)
        with self.assertRaisesRegex(DeliveryError, "dispatch.*refused"):
            controller.dispatch_with_terminal_failure(
                "delivery-pr.yml",
                {"expected_head": "1" * 40},
                {"id": 99},
                "Managed PR CI dispatch failed",
            )
        self.assertEqual("failure", github.updated[0][1]["conclusion"])
        self.assertEqual(
            "Managed PR CI dispatch failed", github.updated[0][1]["title"]
        )

    def test_superseded_pending_head_is_terminally_failed(self) -> None:
        head = "1" * 40
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "delivery-admission",
                "status": "in_progress",
                "app": {"slug": "github-actions"},
                "external_id": f"delivery:v1:41:{head}:{'a' * 64}",
            }
        )
        Controller(github).fail_superseded_head(41, head)
        self.assertEqual("failure", github.updated[0][1]["conclusion"])

    def test_closed_pull_request_terminally_fails_pending_proof(self) -> None:
        head = "1" * 40
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "in_progress",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{'a' * 64}",
            }
        )
        Controller(github).fail_pending_head(
            41,
            head,
            "Pull request closed",
            "Pull request #41 closed before the proof completed.",
        )
        self.assertEqual("Pull request closed", github.updated[0][1]["title"])
        self.assertEqual("failure", github.updated[0][1]["conclusion"])

    def test_fork_refusal_is_explicit(self) -> None:
        controller = Controller(FakeGitHub())
        with self.assertRaisesRegex(DeliveryError, "refuses fork heads"):
            controller.require_same_repository(
                {"head": {"repo": {"full_name": "somebody/lwpt"}}}
            )

    def test_singleton_full_ci_scope_is_exact_head(self) -> None:
        snapshot = derive_candidate_snapshot(fixture("singleton.json"))
        self.assertEqual("singleton", snapshot["mode"])
        self.assertEqual([41], [entry["number"] for entry in snapshot["entries"]])
        self.assertTrue(snapshot_requires_full_ci(snapshot))

    def test_native_prefix_is_bottom_through_candidate(self) -> None:
        snapshot = derive_candidate_snapshot(fixture("stack.json"))
        self.assertEqual("native-prefix", snapshot["mode"])
        self.assertEqual([41, 42, 43], [entry["number"] for entry in snapshot["entries"]])
        self.assertTrue(snapshot_requires_full_ci(snapshot))

    def test_changed_topology_invalidates_digest(self) -> None:
        original = fixture("stack.json")
        changed = copy.deepcopy(original)
        changed["stack"]["entries"]["nodes"][1]["pullRequest"]["headRefOid"] = "4" * 40
        self.assertNotEqual(
            snapshot_digest(derive_candidate_snapshot(original)),
            snapshot_digest(derive_candidate_snapshot(changed)),
        )

    def test_phase_labels_do_not_change_topology_digest(self) -> None:
        original = fixture("stack.json")
        changed = copy.deepcopy(original)
        changed["stack"]["entries"]["nodes"][1]["pullRequest"]["labels"]["nodes"].append(
            {"name": "ci:ready"}
        )
        self.assertEqual(
            snapshot_digest(derive_candidate_snapshot(original)),
            snapshot_digest(derive_candidate_snapshot(changed)),
        )

    def test_full_ci_policy_change_invalidates_topology_digest(self) -> None:
        original = fixture("stack.json")
        changed = copy.deepcopy(original)
        changed["stack"]["entries"]["nodes"][1]["pullRequest"]["labels"]["nodes"] = [
            {"name": "delivery:managed"}
        ]
        self.assertNotEqual(
            snapshot_digest(derive_candidate_snapshot(original)),
            snapshot_digest(derive_candidate_snapshot(changed)),
        )

    def test_non_contiguous_native_prefix_fails_closed(self) -> None:
        changed = fixture("stack.json")
        changed["stack"]["entries"]["nodes"].pop(1)
        with self.assertRaisesRegex(DeliveryError, "not contiguous"):
            derive_candidate_snapshot(changed)

    def test_matrix_failure_and_cancellation_are_terminal_failures(self) -> None:
        self.assertEqual(("failure", "Workflow concluded failure"), workflow_conclusion("failure"))
        self.assertEqual(("failure", "Workflow concluded cancelled"), workflow_conclusion("cancelled"))

    def test_watchdog_recovers_at_the_documented_boundary(self) -> None:
        now = datetime(2026, 8, 4, 12, 0, tzinfo=timezone.utc)
        started = (now - timedelta(minutes=120)).isoformat()
        self.assertTrue(watchdog_expired(started, 120, now))
        self.assertFalse(watchdog_expired(started, 121, now))

    def test_watchdog_age_must_be_positive(self) -> None:
        self.assertEqual(1, positive_integer("1"))
        with self.assertRaisesRegex(argparse.ArgumentTypeError, "positive integer"):
            positive_integer("0")
        with self.assertRaisesRegex(argparse.ArgumentTypeError, "positive integer"):
            positive_integer("-1")

    def test_review_requires_terminal_head_thread_resolution_and_reply(self) -> None:
        automations = [
            {
                "id": "reviewer",
                "actors": ["reviewer[bot]"],
                "check_context": "Reviewer",
                "terminal_review_states": ["COMMENTED"],
            }
        ]
        checks = [
            {"id": 1, "name": "Reviewer", "conclusion": "failure"},
            {"id": 2, "name": "Reviewer", "conclusion": "success"},
        ]
        reviews = [
            {
                "author": {"login": "reviewer[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "COMMENTED",
            }
        ]
        threads = [
            {
                "isResolved": True,
                "comments": [
                    {"author": {"login": "reviewer[bot]"}},
                    {"author": {"login": "maintainer"}},
                ],
            }
        ]
        self.assertEqual(
            [],
            review_evidence_errors(
                "a" * 40, automations, checks, reviews, threads, {"maintainer"}
            ),
        )
        threads[0]["isResolved"] = False
        threads[0]["comments"].pop()
        errors = review_evidence_errors(
            "a" * 40, automations, checks, reviews, threads, set()
        )
        self.assertIn("thread 1: unresolved", errors)
        self.assertIn("thread 1: no current maintainer reply", errors)

    def test_only_current_head_automations_are_active(self) -> None:
        automations = [
            {
                "id": "coderabbit",
                "actors": ["coderabbitai[bot]"],
                "check_contexts": ["CodeRabbit"],
            },
            {
                "id": "macroscope",
                "actors": ["macroscopeapp"],
                "check_contexts": ["Macroscope - Correctness Check"],
                "check_app_slugs": ["macroscopeapp"],
                "terminal_check_conclusions": ["success", "neutral"],
            },
        ]
        checks = [
            {
                "id": 4,
                "name": "Macroscope - Correctness Check",
                "conclusion": "neutral",
                "app": {"slug": "macroscopeapp"},
            }
        ]
        reviews = [
            {
                "author": {"login": "macroscopeapp"},
                "commit": {"oid": "a" * 40},
                "state": "COMMENTED",
            },
            {
                "author": {"login": "coderabbitai[bot]"},
                "commit": {"oid": "b" * 40},
                "state": "COMMENTED",
            },
        ]
        self.assertEqual(
            [],
            review_evidence_errors(
                "a" * 40, automations, checks, reviews, [], set()
            ),
        )

        checks[0]["app"] = {"slug": "lookalike"}
        self.assertEqual(
            ["macroscope: terminal current-head check is missing"],
            review_evidence_errors(
                "a" * 40, automations, checks, reviews, [], set()
            ),
        )

    def test_every_active_automation_must_converge(self) -> None:
        automations = [
            {
                "id": "hosted",
                "actors": ["hosted[bot]"],
                "check_contexts": ["Hosted review"],
            },
            {
                "id": "custom",
                "actors": ["custom-reviewer"],
                "check_contexts": ["Custom review"],
                "terminal_review_states": [],
            },
        ]
        checks = [
            {"id": 1, "name": "Hosted review", "conclusion": "success"},
            {"id": 2, "name": "Custom review", "conclusion": None},
        ]
        reviews = [
            {
                "author": {"login": "hosted[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "COMMENTED",
            }
        ]
        self.assertEqual(
            ["custom: terminal current-head check is missing"],
            review_evidence_errors(
                "a" * 40, automations, checks, reviews, [], set()
            ),
        )
        checks[1]["conclusion"] = "success"
        self.assertEqual(
            [],
            review_evidence_errors(
                "a" * 40, automations, checks, reviews, [], set()
            ),
        )

    def test_maintainer_comment_before_automation_is_not_a_reply(self) -> None:
        automations = [{"id": "reviewer", "actors": ["reviewer[bot]"]}]
        threads = [
            {
                "isResolved": True,
                "comments": [
                    {"author": {"login": "maintainer"}},
                    {"author": {"login": "reviewer[bot]"}},
                ],
            }
        ]
        errors = review_evidence_errors(
            "a" * 40, automations, [], [], threads, {"maintainer"}
        )
        self.assertIn("thread 1: no current maintainer reply", errors)

    def test_rate_limit_without_terminal_review_remains_pending(self) -> None:
        automations = [{"id": "reviewer", "actors": ["reviewer[bot]"]}]
        errors = review_evidence_errors("a" * 40, automations, [], [], [], set())
        self.assertEqual(
            ["no configured review automation has current-head evidence"], errors
        )

    def test_active_nonterminal_review_fails_closed(self) -> None:
        automations = [{"id": "reviewer", "actors": ["reviewer[bot]"]}]
        reviews = [
            {
                "author": {"login": "reviewer[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "PENDING",
            }
        ]
        self.assertEqual(
            ["reviewer: terminal current-head review is missing"],
            review_evidence_errors(
                "a" * 40, automations, [], reviews, [], set()
            ),
        )

    def test_latest_rate_limited_review_fails_closed(self) -> None:
        automations = [
            {
                "id": "reviewer",
                "actors": ["reviewer[bot]"],
                "nonterminal_review_markers": ["quota exceeded"],
            }
        ]
        reviews = [
            {
                "author": {"login": "reviewer[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "COMMENTED",
                "body": "Review complete",
                "submittedAt": "2026-08-11T10:00:00Z",
            },
            {
                "author": {"login": "reviewer[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "COMMENTED",
                "body": "Quota exceeded; retry later",
                "submittedAt": "2026-08-11T10:01:00Z",
            },
        ]
        self.assertEqual(
            ["reviewer: terminal current-head review is missing"],
            review_evidence_errors(
                "a" * 40, automations, [], reviews, [], set()
            ),
        )


if __name__ == "__main__":
    unittest.main()
