from __future__ import annotations

import argparse
import copy
import json
import sys
import tempfile
import unittest
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path


DELIVERY_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DELIVERY_DIR))

from controller import (  # noqa: E402
    Controller,
    DIAGNOSTIC_RUN_RE,
    FULL_CI_RUN_RE,
    GitHub,
    positive_integer,
)
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


class RecoveryGitHub(FakeCheckGitHub):
    def __init__(self, check: dict, run: dict, head: str) -> None:
        super().__init__(check)
        self.run = run
        self.head = head
        self.created_after: datetime | None = None

    def open_pulls(self) -> list[dict]:
        return [{"number": 41, "head": {"sha": self.head}}]

    def completed_workflow_runs(
        self,
        workflow: str,
        created_after: datetime,
        created_before: datetime | None = None,
    ) -> list[dict]:
        self.created_after = created_after
        return [self.run]

    def update_check(self, check_id: int, **fields: object) -> None:
        super().update_check(check_id, **fields)
        if fields.get("conclusion"):
            self.check["status"] = "completed"


class DiagnosticGitHub(FakeGitHub):
    server_url = "https://github.com"

    def __init__(self, head: str) -> None:
        self.head = head
        self.dispatched: list[tuple[str, dict[str, str]]] = []
        self.cancelled: list[int] = []
        self.runs: list[dict] = []
        self.checks: dict[int, dict] = {}
        self.updated: list[tuple[int, dict]] = []
        self.rerun_ids: list[int] = []
        self.workflow_lookups: list[tuple[str, str, int, str]] = []
        self.labels: list[tuple[int, list[str]]] = []
        self.removed_labels: list[tuple[int, str]] = []
        self.draft_ids: list[str] = []

    def pull(self, number: int) -> dict:
        return {
            "number": number,
            "node_id": f"PR_{number}",
            "state": "open",
            "draft": False,
            "base": {"sha": "2" * 40},
            "head": {"sha": self.head, "repo": {"full_name": self.repository}},
        }

    def dispatch(self, workflow: str, inputs: dict[str, str]) -> None:
        self.dispatched.append((workflow, inputs))

    def workflow_runs(self, workflow: str) -> list[dict]:
        return self.runs

    def check_runs(self, head: str) -> list[dict]:
        return list(self.checks.values())

    def review_evidence(self, number: int) -> tuple[list[dict], list[dict]]:
        return [], []

    def check_run(self, check_id: int) -> dict:
        return self.checks[check_id]

    def cancel_run(self, run_id: int) -> None:
        self.cancelled.append(run_id)

    def update_check(self, check_id: int, **fields: object) -> None:
        self.updated.append((check_id, fields))
        if fields.get("conclusion"):
            self.checks[check_id]["status"] = "completed"

    def pull_request_workflow_run(
        self, workflow: str, head: str, number: int, base: str
    ) -> dict:
        self.workflow_lookups.append((workflow, head, number, base))
        return {"id": 77, "head_sha": head, "status": "completed"}

    def rerun(self, run_id: int) -> None:
        self.rerun_ids.append(run_id)

    def add_labels(self, number: int, labels: list[str]) -> None:
        self.labels.append((number, labels))

    def remove_label(self, number: int, label: str) -> None:
        self.removed_labels.append((number, label))

    def mark_draft(self, node_id: str) -> None:
        self.draft_ids.append(node_id)

    def create_check(
        self, name: str, head: str, external_id: str, title: str, summary: str
    ) -> dict:
        return {"id": 99, "status": "in_progress"}


class PromotionController(Controller):
    def __init__(self, github: DiagnosticGitHub) -> None:
        super().__init__(github)
        self.preflight: list[str] = []

    def snapshot(self, number: int) -> tuple[dict, str]:
        return (
            {
                "mode": "singleton",
                "candidate": number,
                "entries": [
                    {
                        "number": number,
                        "head": "1" * 40,
                        "base": "2" * 40,
                        "base_ref": "main",
                        "full_ci_required": True,
                    }
                ],
            },
            "a" * 64,
        )

    def require_delivery_success(self, number: int, expected_head: str) -> dict:
        self.preflight.append("pr-ci")
        return {"conclusion": "success"}

    def validate_reviews(self, number: int, head: str) -> str:
        self.preflight.append(f"review:{number}")
        return f"fingerprint:{number}"


class PrefixPromotionController(PromotionController):
    def snapshot(self, number: int) -> tuple[dict, str]:
        snapshot = {
                "mode": "native-prefix",
                "candidate": number,
                "entries": [
                    {
                        "number": 40,
                        "head": "0" * 40,
                        "base": "a" * 40,
                        "base_ref": "main",
                        "full_ci_required": True,
                    },
                    {
                        "number": 41,
                        "head": "1" * 40,
                        "base": "0" * 40,
                        "base_ref": "feature-one",
                        "full_ci_required": False,
                    },
                ],
            }
        return snapshot, snapshot_digest(snapshot)

    def current_pull(self, number: int, expected_head: str | None = None) -> dict:
        self.preflight.append(f"current:{number}")
        return {
            "number": number,
            "state": "open",
            "mergeable": True,
            "mergeable_state": "clean",
            "base": {"sha": "a" * 40 if number == 40 else "0" * 40},
            "head": {
                "sha": "0" * 40 if number == 40 else "1" * 40,
                "repo": {"full_name": self.github.repository},
            },
        }

    def require_delivery_success(self, number: int, expected_head: str) -> dict:
        self.preflight.append(f"pr-ci:{number}")
        return {"conclusion": "success"}


class DeliveryModelTests(unittest.TestCase):
    def test_exact_head_accepts_only_current_sha(self) -> None:
        pull = {"head": {"sha": "a" * 40}}
        require_expected_head(pull, "a" * 40)
        with self.assertRaisesRegex(DeliveryError, "stale head"):
            require_expected_head(pull, "b" * 40)

    def test_finalizer_rejects_an_unowned_check_id(self) -> None:
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "app": {"slug": "some-other-app"},
                "external_id": f"full-ci:v1:41:{'1' * 40}:{'a' * 64}",
            }
        )
        controller = Controller(github)
        with self.assertRaisesRegex(DeliveryError, "not the expected app-owned"):
            controller.require_owned_check(
                99,
                "full-ci",
                f"full-ci:v1:41:{'1' * 40}:{'a' * 64}",
            )
        self.assertEqual([], github.updated)

    def test_native_pr_checks_are_the_delivery_proof(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        github.check_runs = lambda _: [  # type: ignore[method-assign]
            {
                "id": 1,
                "name": "delivery-admission",
                "status": "completed",
                "conclusion": "success",
                "details_url": "https://github.com/frostney/lwpt/actions/runs/77/job/1",
                "app": {"slug": "github-actions"},
            },
            {
                "id": 2,
                "name": "delivery-admission",
                "status": "completed",
                "conclusion": "failure",
                "external_id": f"delivery:v1:41:{head}:{'a' * 64}",
                "app": {"slug": "github-actions"},
            },
        ]
        self.assertEqual(
            "success", Controller(github).require_delivery_success(41, head)["conclusion"]
        )
        github.check_runs = lambda _: []  # type: ignore[method-assign]
        with self.assertRaisesRegex(DeliveryError, "native delivery-admission job"):
            Controller(github).require_delivery_success(41, head)

    def test_managed_ci_admits_and_reruns_the_existing_exact_head_workflow(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_pull  # type: ignore[method-assign]
        Controller(github).ci(41, head)
        self.assertEqual([("pr.yml", head, 41, "2" * 40)], github.workflow_lookups)
        self.assertEqual([77], github.rerun_ids)
        self.assertIn((41, ["ci:ready"]), github.labels)

    def test_reset_clears_readiness_and_returns_the_pull_to_draft(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_pull  # type: ignore[method-assign]
        Controller(github).reset(41, head)
        self.assertEqual(["PR_41"], github.draft_ids)
        self.assertEqual(
            [(41, label) for label in ("ci:ready", "review:ready", "merge:ready")],
            github.removed_labels,
        )

    def test_review_opens_the_phase_for_a_managed_ready_pull_after_ci(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_pull  # type: ignore[method-assign]
        controller = PromotionController(github)
        controller.review(41, head)
        self.assertEqual(["pr-ci"], controller.preflight)
        self.assertEqual([(41, ["ci:ready", "review:ready"])], github.labels)

    def test_review_is_idempotent_when_the_managed_pull_is_already_ready(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_pull  # type: ignore[method-assign]
        controller = PromotionController(github)
        controller.review(41, head)
        controller.review(41, head)
        self.assertEqual(
            [
                (41, ["ci:ready", "review:ready"]),
                (41, ["ci:ready", "review:ready"]),
            ],
            github.labels,
        )

    def test_review_refusal_does_not_open_an_unmanaged_pull(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        with self.assertRaisesRegex(DeliveryError, "not delivery:managed"):
            PromotionController(github).review(41, head)
        self.assertEqual([], github.labels)

    def test_review_refusal_does_not_open_a_draft_without_successful_ci(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_draft(number: int) -> dict:
            pull = original_pull(number)
            pull["draft"] = True
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_draft  # type: ignore[method-assign]
        controller = PromotionController(github)

        def failed_ci(number: int, expected_head: str) -> dict:
            raise DeliveryError("exact-head CI is not successful")

        controller.require_delivery_success = failed_ci  # type: ignore[method-assign]
        with self.assertRaisesRegex(DeliveryError, "CI is not successful"):
            controller.review(41, head)
        self.assertEqual([], github.labels)

    def test_review_requires_the_harness_to_mark_the_admitted_draft_ready(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def managed_draft(number: int) -> dict:
            pull = original_pull(number)
            pull["draft"] = True
            pull["labels"] = [{"name": "delivery:managed"}]
            return pull

        github.pull = managed_draft  # type: ignore[method-assign]
        with self.assertRaisesRegex(DeliveryError, "must be marked ready"):
            PromotionController(github).review(41, head)
        self.assertEqual([], github.labels)

    def test_merge_refuses_a_pull_returned_to_draft(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        class MergeController(PromotionController):
            def require_full_ci(
                self, candidate: int, snapshot: dict, digest: str
            ) -> None:
                self.preflight.append(f"full-ci:{candidate}")

        def admitted_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["draft"] = True
            pull["labels"] = [
                {"name": "delivery:managed"},
                {"name": "review:ready"},
            ]
            return pull

        github.pull = admitted_pull  # type: ignore[method-assign]
        with self.assertRaisesRegex(DeliveryError, "still a draft"):
            MergeController(github).merge(41, head, 41)
        self.assertEqual([], github.labels)

    def test_observer_invalidates_review_when_a_managed_pull_returns_to_draft(
        self,
    ) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def converted_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["draft"] = True
            pull["labels"] = [
                {"name": "delivery:managed"},
                {"name": "ci:ready"},
                {"name": "review:ready"},
                {"name": "merge:ready"},
            ]
            return pull

        class ObserverController(Controller):
            def delivery_check(
                self, number: int, expected_head: str
            ) -> dict | None:
                return {"status": "completed", "conclusion": "success"}

        github.pull = converted_pull  # type: ignore[method-assign]
        ObserverController(github).observe_one(41)
        self.assertEqual(
            [(41, "review:ready"), (41, "merge:ready")],
            github.removed_labels,
        )

    def test_diagnostic_dispatch_is_allow_listed_and_not_a_full_ci_proof(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        controller = Controller(github)
        controller.diagnostic(41, head, "x86_64-win64", "tls")
        self.assertEqual(
            [
                (
                    "ci.yml",
                    {
                        "mode": "diagnostic",
                        "candidate_pr_number": "41",
                        "expected_head": head,
                        "diagnostic_target": "x86_64-win64",
                        "diagnostic_selector": "tls",
                    },
                )
            ],
            github.dispatched,
        )
        title = f"diagnostic/41/{head}/x86_64-win64/tls"
        self.assertIsNotNone(DIAGNOSTIC_RUN_RE.match(title))
        self.assertIsNone(FULL_CI_RUN_RE.match(title))
        with self.assertRaisesRegex(DeliveryError, "unsupported diagnostic target"):
            controller.diagnostic(41, head, "windows-latest", "tls")

    def test_diagnostic_refuses_a_stale_head(self) -> None:
        controller = Controller(DiagnosticGitHub("1" * 40))
        with self.assertRaisesRegex(DeliveryError, "stale head"):
            controller.diagnostic(41, "2" * 40, "i386-win32", "default")

    def test_intel_darwin_scheduling_diagnostic_is_allow_listed(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        Controller(github).diagnostic(
            41, head, "x86_64-darwin", "scheduling"
        )
        self.assertEqual("diagnostic", github.dispatched[0][1]["mode"])
        self.assertEqual(
            "x86_64-darwin", github.dispatched[0][1]["diagnostic_target"]
        )
        self.assertEqual(
            "scheduling", github.dispatched[0][1]["diagnostic_selector"]
        )
        self.assertIsNotNone(
            DIAGNOSTIC_RUN_RE.match(
                f"diagnostic/41/{head}/x86_64-darwin/scheduling"
            )
        )
        Controller(DiagnosticGitHub(head)).diagnostic(
            41, head, "x86_64-darwin", "default"
        )
        with self.assertRaisesRegex(DeliveryError, "unsupported diagnostic slice"):
            Controller(DiagnosticGitHub(head)).diagnostic(
                41, head, "x86_64-win64", "scheduling"
            )
        self.assertIsNone(
            DIAGNOSTIC_RUN_RE.match(
                f"diagnostic/41/{head}/x86_64-darwin/tls"
            )
        )

    def test_superseded_diagnostic_and_full_ci_runs_are_cancelled(self) -> None:
        head = "1" * 40
        digest = "a" * 64
        github = DiagnosticGitHub(head)
        github.runs = [
            {
                "id": 1,
                "status": "in_progress",
                "display_title": f"diagnostic/41/{'2' * 40}/x86_64-win64/tls",
            },
            {
                "id": 2,
                "status": "queued",
                "display_title": f"full-ci/41/{head}/{'b' * 64}/99",
            },
            {
                "id": 3,
                "status": "in_progress",
                "display_title": f"full-ci/41/{head}/{digest}/100",
            },
        ]
        Controller(github).cancel_superseded_ci_runs(41, head, digest)
        self.assertEqual([1, 2], github.cancelled)

    def test_review_change_cancels_current_full_ci_but_not_diagnostic(self) -> None:
        head = "1" * 40
        digest = "a" * 64
        github = DiagnosticGitHub(head)
        github.runs = [
            {
                "id": 1,
                "status": "in_progress",
                "display_title": f"diagnostic/41/{head}/x86_64-win64/tls",
            },
            {
                "id": 2,
                "status": "in_progress",
                "display_title": f"full-ci/41/{head}/{digest}/99",
            },
        ]
        Controller(github).cancel_superseded_ci_runs(
            41, head, digest, review_changed=True
        )
        self.assertEqual([2], github.cancelled)

    def test_full_ci_is_dispatched_only_after_terminal_preflight(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        controller = PromotionController(github)
        controller.full_ci(41, head)
        self.assertEqual(["pr-ci", "review:41"], controller.preflight)
        self.assertEqual("full-ci", github.dispatched[0][1]["mode"])

    def test_completed_full_ci_rejects_changed_review_evidence(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "completed",
                "conclusion": "success",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{digest}",
                "output": {
                    "summary": "proof\n\n"
                    + Controller.full_ci_evidence_blocks(
                        snapshot, {"41": "promotion-fingerprint"}
                    )
                },
            }
        )
        controller = Controller(github)
        controller.validate_reviews = (  # type: ignore[method-assign]
            lambda number, member_head: "changed-fingerprint"
        )
        with self.assertRaisesRegex(DeliveryError, "changed after full-CI promotion"):
            controller.require_full_ci(41, snapshot, digest)

    def test_full_ci_finalizer_preserves_bound_review_evidence(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        fingerprints = {"41": "promotion-fingerprint"}
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "in_progress",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{digest}",
                "output": {
                    "summary": "proof\n\n"
                    + Controller.full_ci_evidence_blocks(snapshot, fingerprints)
                },
            }
        )
        controller = Controller(github)
        controller.current_pull = (  # type: ignore[method-assign]
            lambda number, expected_head=None: {"number": number}
        )
        controller.snapshot = lambda number: (snapshot, digest)  # type: ignore[method-assign]
        controller.validate_reviews = (  # type: ignore[method-assign]
            lambda number, member_head: fingerprints[str(number)]
        )
        match = FULL_CI_RUN_RE.match(f"full-ci/41/{head}/{digest}/99")
        self.assertIsNotNone(match)
        controller.finalize_full_ci(
            {"id": 7, "conclusion": "success", "html_url": "https://example.test/run/7"},
            match,
        )
        self.assertIn(
            "```review-evidence\n"
            + json.dumps(fingerprints, sort_keys=True, separators=(",", ":"))
            + "\n```",
            github.updated[0][1]["summary"],
        )

    def test_full_ci_finalizer_rejects_review_change_during_run(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "in_progress",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{digest}",
                "output": {
                    "summary": Controller.full_ci_evidence_blocks(
                        snapshot, {"41": "promotion-fingerprint"}
                    )
                },
            }
        )
        github.remove_label = lambda number, label: None  # type: ignore[attr-defined]
        controller = Controller(github)
        controller.current_pull = (  # type: ignore[method-assign]
            lambda number, expected_head=None: {}
        )
        controller.snapshot = (  # type: ignore[method-assign]
            lambda number: (snapshot, digest)
        )
        controller.validate_reviews = (  # type: ignore[method-assign]
            lambda number, member_head: "changed-fingerprint"
        )
        match = FULL_CI_RUN_RE.match(f"full-ci/41/{head}/{digest}/99")
        self.assertIsNotNone(match)
        controller.finalize_full_ci(
            {"id": 7, "conclusion": "success", "html_url": "https://example.test/run/7"},
            match,
        )
        self.assertEqual("failure", github.updated[0][1]["conclusion"])
        self.assertIn("changed during full CI", github.updated[0][1]["summary"])

    def test_watchdog_recovers_a_token_dispatched_terminal_full_ci(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        fingerprints = {"41": "promotion-fingerprint"}
        check = {
            "id": 99,
            "name": "full-ci",
            "status": "in_progress",
            "started_at": "2026-08-12T11:00:00Z",
            "app": {"slug": "github-actions"},
            "external_id": f"full-ci:v1:41:{head}:{digest}",
            "output": {
                "summary": Controller.full_ci_evidence_blocks(
                    snapshot, fingerprints
                )
            },
        }
        run = {
            "id": 7,
            "display_title": f"full-ci/41/{head}/{digest}/99",
            "conclusion": "success",
            "html_url": "https://example.test/run/7",
        }
        github = RecoveryGitHub(check, run, head)
        controller = Controller(github)
        controller.current_pull = (  # type: ignore[method-assign]
            lambda number, expected_head=None: {"number": number}
        )
        controller.snapshot = lambda number: (snapshot, digest)  # type: ignore[method-assign]
        controller.validate_reviews = (  # type: ignore[method-assign]
            lambda number, member_head: fingerprints[str(number)]
        )

        controller.watchdog(120)
        controller.watchdog(120)

        self.assertEqual(1, len(github.updated))
        self.assertEqual("success", github.updated[0][1]["conclusion"])
        self.assertIsNotNone(github.created_after)

    def test_completed_run_query_is_time_bounded(self) -> None:
        github = object.__new__(GitHub)
        github.repository = "frostney/lwpt"
        requested: list[str] = []

        def request(method: str, path: str, payload: object | None = None) -> dict:
            requested.append(path)
            return {
                "total_count": 2,
                "workflow_runs": [{"id": 1}, {"id": 2}],
            }

        github.request = request  # type: ignore[method-assign]
        runs = github.completed_workflow_runs(
            "ci.yml",
            datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc),
            datetime(2026, 8, 12, 11, 0, tzinfo=timezone.utc),
        )

        self.assertEqual([1, 2], [run["id"] for run in runs])
        self.assertEqual(1, len(requested))
        self.assertIn("status=completed", requested[0])
        self.assertIn(
            "created=2026-08-12T10%3A00%3A00Z..2026-08-12T11%3A00%3A00Z",
            requested[0],
        )

    def test_completed_run_query_splits_github_result_cap(self) -> None:
        github = object.__new__(GitHub)
        github.repository = "frostney/lwpt"
        requested: list[str] = []

        def request(method: str, path: str, payload: object | None = None) -> dict:
            requested.append(path)
            created = urllib.parse.parse_qs(
                urllib.parse.urlsplit(path).query
            )["created"][0]
            if created == "2026-08-12T10:00:00Z..2026-08-12T12:00:00Z":
                return {"total_count": 101, "workflow_runs": []}
            run_id = 1 if created.endswith("..2026-08-12T11:00:00Z") else 2
            return {"total_count": 1, "workflow_runs": [{"id": run_id}]}

        github.request = request  # type: ignore[method-assign]
        runs = github.completed_workflow_runs(
            "ci.yml",
            datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc),
            datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc),
        )

        self.assertEqual([1, 2], [run["id"] for run in runs])
        self.assertEqual(3, len(requested))

    def test_completed_full_ci_accepts_unchanged_review_evidence(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        fingerprint = "promotion-fingerprint"
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "completed",
                "conclusion": "success",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{digest}",
                "output": {
                    "summary": Controller.full_ci_evidence_blocks(
                        snapshot, {"41": fingerprint}
                    )
                },
            }
        )
        controller = Controller(github)
        controller.validate_reviews = (  # type: ignore[method-assign]
            lambda number, member_head: fingerprint
        )
        controller.require_full_ci(41, snapshot, digest)

    def test_completed_full_ci_rejects_missing_review_evidence(self) -> None:
        head = "1" * 40
        snapshot = PromotionController(DiagnosticGitHub(head)).snapshot(41)[0]
        digest = snapshot_digest(snapshot)
        github = FakeCheckGitHub(
            {
                "id": 99,
                "name": "full-ci",
                "status": "completed",
                "conclusion": "success",
                "app": {"slug": "github-actions"},
                "external_id": f"full-ci:v1:41:{head}:{digest}",
                "output": {"summary": "```json\n{}\n```"},
            }
        )
        with self.assertRaisesRegex(DeliveryError, "lacks bound evidence"):
            Controller(github).require_full_ci(41, snapshot, digest)

    def test_full_ci_redispatches_after_successful_proof_review_change(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        controller = PromotionController(github)
        snapshot, digest = controller.snapshot(41)
        stale = {
            "id": 98,
            "name": "full-ci",
            "status": "completed",
            "conclusion": "success",
            "app": {"slug": "github-actions"},
            "external_id": f"full-ci:v1:41:{head}:{digest}",
            "output": {
                "summary": Controller.full_ci_evidence_blocks(
                    snapshot, {"41": "old-fingerprint"}
                )
            },
        }
        github.check_runs = lambda member_head: [stale]  # type: ignore[method-assign]
        controller.full_ci(41, head)
        self.assertEqual("full-ci", github.dispatched[0][1]["mode"])

    def test_native_prefix_promotion_validates_every_member(self) -> None:
        github = DiagnosticGitHub("1" * 40)
        controller = PrefixPromotionController(github)
        controller.full_ci(41, "1" * 40)
        self.assertIn("current:40", controller.preflight)
        self.assertIn("pr-ci:40", controller.preflight)
        self.assertIn("review:40", controller.preflight)
        self.assertIn("current:41", controller.preflight)
        self.assertIn("pr-ci:41", controller.preflight)
        self.assertIn("review:41", controller.preflight)

    def test_lower_prefix_review_change_cancels_candidate_full_ci(self) -> None:
        lower_head = "0" * 40
        top_head = "1" * 40
        snapshot, digest = PrefixPromotionController(
            DiagnosticGitHub(top_head)
        ).snapshot(41)
        github = DiagnosticGitHub(top_head)
        github.checks[99] = {
            "id": 99,
            "status": "in_progress",
            "name": "full-ci",
            "app": {"slug": "github-actions"},
            "output": {
                "summary": "proof\n\n```json\n"
                + json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
                + "\n```"
            },
        }
        github.runs = [
            {
                "id": 7,
                "status": "in_progress",
                "display_title": f"full-ci/41/{top_head}/{digest}/99",
            }
        ]
        controller = Controller(github)
        controller.cancel_superseded_ci_runs(
            40, lower_head, "ignored", review_changed=True
        )
        self.assertEqual([7], github.cancelled)

    def test_configured_review_check_is_provider_neutral(self) -> None:
        controller = Controller(DiagnosticGitHub("1" * 40))
        self.assertTrue(
            controller.is_review_check(
                {
                    "name": "Macroscope - Correctness Check",
                    "app": {"slug": "macroscopeapp"},
                }
            )
        )
        self.assertFalse(
            controller.is_review_check(
                {"name": "build-and-test", "app": {"slug": "github-actions"}}
            )
        )

    def test_unrelated_check_event_does_not_sweep_managed_pulls(self) -> None:
        github = DiagnosticGitHub("1" * 40)
        open_pull_calls = 0

        def open_pulls() -> list[dict]:
            nonlocal open_pull_calls
            open_pull_calls += 1
            return []

        github.open_pulls = open_pulls  # type: ignore[attr-defined]
        event = {
            "action": "completed",
            "check_run": {
                "name": "Some other external check",
                "app": {"slug": "some-other-app"},
                "pull_requests": [{"number": 41}],
            },
        }
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "event.json"
            path.write_text(json.dumps(event), encoding="utf-8")
            Controller(github).observe(str(path))

        self.assertEqual(0, open_pull_calls)

    def test_review_invalidation_cancels_before_preserving_prefix_evidence(self) -> None:
        lower_head = "0" * 40
        top_head = "1" * 40
        snapshot, digest = PrefixPromotionController(
            DiagnosticGitHub(top_head)
        ).snapshot(41)
        github = DiagnosticGitHub(top_head)
        encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
        github.checks[99] = {
            "id": 99,
            "status": "in_progress",
            "started_at": "2026-08-11T12:00:00Z",
            "name": "full-ci",
            "app": {"slug": "github-actions"},
            "output": {"summary": f"proof\n\n```json\n{encoded}\n```"},
        }
        github.runs = [
            {
                "id": 8,
                "status": "in_progress",
                "display_title": f"full-ci/41/{top_head}/{digest}/99",
            }
        ]
        controller = Controller(github)
        fingerprint = controller.review_fingerprint(
            [], [], [], controller.automations
        )
        github.checks[99]["output"]["summary"] += (
            "\n\n```review-evidence\n"
            + json.dumps(
                {"40": fingerprint, "41": fingerprint}, separators=(",", ":")
            )
            + "\n```"
        )
        controller.invalidate_active_full_ci_for_member(
            40,
            "Review evidence changed",
            "lower member changed",
            force=True,
        )
        self.assertEqual([8], github.cancelled)
        self.assertEqual("failure", github.updated[0][1]["conclusion"])
        self.assertIn(encoded, github.updated[0][1]["summary"])

    def test_delayed_consumed_review_event_does_not_cancel_full_ci(self) -> None:
        top_head = "1" * 40
        snapshot, digest = PrefixPromotionController(
            DiagnosticGitHub(top_head)
        ).snapshot(41)
        github = DiagnosticGitHub(top_head)
        controller = Controller(github)
        fingerprint = controller.review_fingerprint(
            [], [], [], controller.automations
        )
        encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
        github.checks[99] = {
            "id": 99,
            "status": "in_progress",
            "started_at": "2026-08-11T12:00:00Z",
            "name": "full-ci",
            "app": {"slug": "github-actions"},
            "output": {
                "summary": f"proof\n\n```json\n{encoded}\n```"
                + "\n\n```review-evidence\n"
                + json.dumps({"40": fingerprint}, separators=(",", ":"))
                + "\n```"
            },
        }
        github.runs = [
            {
                "id": 9,
                "status": "in_progress",
                "display_title": f"full-ci/41/{top_head}/{digest}/99",
            }
        ]
        controller.invalidate_active_full_ci_for_member(
            40,
            "Review evidence changed",
            "delayed event",
        )
        self.assertEqual([], github.cancelled)
        self.assertEqual([], github.updated)

    def test_full_ci_refuses_a_branch_behind_its_base(self) -> None:
        head = "1" * 40
        github = DiagnosticGitHub(head)
        original_pull = github.pull

        def behind_pull(number: int) -> dict:
            pull = original_pull(number)
            pull["mergeable_state"] = "behind"
            return pull

        github.pull = behind_pull  # type: ignore[method-assign]
        with self.assertRaisesRegex(DeliveryError, "current base"):
            PromotionController(github).full_ci(41, head)

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

    def test_nullable_github_review_fields_fail_closed(self) -> None:
        automations = [{"id": "reviewer", "actors": ["reviewer[bot]"]}]
        reviews = [
            {
                "author": None,
                "commit": None,
                "state": "PENDING",
                "submittedAt": None,
            },
            {
                "author": {"login": "reviewer[bot]"},
                "commit": {"oid": "a" * 40},
                "state": "PENDING",
                "submittedAt": None,
            },
        ]
        self.assertEqual(
            ["reviewer: terminal current-head review is missing"],
            review_evidence_errors(
                "a" * 40, automations, [], reviews, [], set()
            ),
        )

    def test_nullable_check_and_comment_authors_do_not_crash(self) -> None:
        automations = [
            {
                "id": "reviewer",
                "actors": ["reviewer[bot]"],
                "check_contexts": ["Review"],
                "check_app_slugs": ["reviewer"],
                "terminal_review_states": [],
            }
        ]
        checks = [{"id": 1, "name": "Review", "conclusion": "success", "app": None}]
        threads = [{"isResolved": True, "comments": [{"author": None}]}]
        self.assertEqual(
            ["no configured review automation has current-head evidence"],
            review_evidence_errors(
                "a" * 40, automations, checks, [], threads, set()
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
