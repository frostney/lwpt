from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class RepositoryPolicyTests(unittest.TestCase):
    def test_orchestration_policy_has_stable_machine_consumer_headings(self) -> None:
        policy = (ROOT / "ORCHESTRATION.md").read_text(encoding="utf-8")
        headings = [
            "## Authority and fallback",
            "## Delivery integration endpoints",
            "## Capability decision tree",
            "## Coordinator and lane responsibilities",
            "## Context packets",
            "## Token ledger",
            "## Intervention thresholds",
            "## Unsupported or contradictory policy handling",
        ]
        for heading in headings:
            self.assertIn(heading, policy)
        for operation in ("enrol", "ci", "review", "full-ci", "merge", "reset"):
            self.assertIn(f"`{operation}`", policy)

    def test_orchestration_policy_pins_every_initial_threshold(self) -> None:
        policy = (ROOT / "ORCHESTRATION.md").read_text(encoding="utf-8")
        for boundary in ("greater than 40%", "greater than 55%", "25th", "at most three"):
            self.assertIn(boundary, policy)
        self.assertIn("fork_turns:none", policy)
        self.assertIn("No token or context intervention may silently downgrade", policy)

    def test_main_ruleset_binds_admission_to_github_actions(self) -> None:
        ruleset = json.loads(
            (ROOT / ".github/rulesets/protect-main.json").read_text(encoding="utf-8")
        )
        pull_rule = next(rule for rule in ruleset["rules"] if rule["type"] == "pull_request")
        self.assertTrue(pull_rule["parameters"]["required_review_thread_resolution"])
        status_rule = next(
            rule for rule in ruleset["rules"] if rule["type"] == "required_status_checks"
        )
        self.assertEqual(
            [{"context": "delivery-admission", "integration_id": 15368}],
            status_rule["parameters"]["required_status_checks"],
        )


if __name__ == "__main__":
    unittest.main()
