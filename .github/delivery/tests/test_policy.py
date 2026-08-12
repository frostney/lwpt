from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def workflow_job(workflow: str, name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n.*?(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"workflow job {name!r} not found")
    return match.group(0)


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
        for operation in (
            "enrol",
            "ci",
            "review",
            "diagnostic",
            "full-ci",
            "merge",
            "reset",
        ):
            self.assertIn(f"`{operation}`", policy)

    def test_token_dispatched_full_ci_has_scheduled_terminal_recovery(self) -> None:
        transition = (
            ROOT / ".github/workflows/delivery-transition.yml"
        ).read_text(encoding="utf-8")
        watchdog = (
            ROOT / ".github/workflows/delivery-watchdog.yml"
        ).read_text(encoding="utf-8")
        controller = (
            ROOT / ".github/delivery/controller.py"
        ).read_text(encoding="utf-8")

        self.assertIn("GH_TOKEN: ${{ github.token }}", transition)
        self.assertIn("cron: '*/15 * * * *'", watchdog)
        self.assertIn("actions: read", watchdog)
        self.assertIn("Reconcile or fail orphaned proofs", watchdog)
        self.assertIn("def recover_completed_full_ci", controller)
        self.assertIn('"ci.yml", created_after, now', controller)

    def test_diagnostics_are_allow_listed_and_proof_separated(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        for value in (
            "x86_64-darwin",
            "x86_64-win64",
            "i386-win32",
            "default",
            "e2e",
            "scheduling",
            "tls",
        ):
            self.assertIn(f"- {value}", workflow)
        self.assertIn("macos-15-intel", workflow)
        self.assertIn("Checkout trusted scheduling diagnostic", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("path: .trusted-delivery", workflow)
        self.assertIn(
            "run: .trusted-delivery/.github/delivery/scheduling-diagnostic.sh",
            workflow,
        )
        diagnostic = (
            ROOT / ".github/delivery/scheduling-diagnostic.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("TestScheduling.Test.pas", diagnostic)
        self.assertIn("diagnostic exceeded its bounded runtime", diagnostic)
        self.assertIn("default) test_selectors=()", diagnostic)
        self.assertIn("diagnostic/", workflow)
        self.assertIn("- diagnostic", workflow)
        self.assertIn("current same-repository PR head", workflow)
        self.assertNotIn("diagnostic:v1", workflow)

    def test_windows_compiler_discovery_skips_absent_roots(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        pr_workflow = (ROOT / ".github/workflows/pr.yml").read_text(encoding="utf-8")
        self.assertIn("for candidate_root in /c/tools/freepascal /c/fpc", workflow)
        self.assertIn('if [ -d "$candidate_root" ]; then', workflow)
        self.assertNotIn("TARGET_FPC=$(find /c/tools/freepascal /c/fpc", workflow)
        self.assertNotIn("Chocolatey FPC install: x86_64 compiler not found", workflow)
        self.assertIn('echo "LWPT_FPC=$LWPT_FPC_VALUE"', workflow)
        self.assertNotIn("FPC target mismatch", workflow)
        self.assertIn('head -1 || true)\n          if [ -n "$INSTANTFPC_BIN" ]', workflow)
        self.assertIn('head -1 || true)\n          if [ -n "$INSTANTFPC_BIN" ]', pr_workflow)
        self.assertIn("for unit_target in i386-win32 x86_64-win64", workflow)
        self.assertNotIn('for unit_target in "${{ matrix.target }}"', workflow)

    def test_native_test_jobs_have_twenty_minute_timeout(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        pr_workflow = (ROOT / ".github/workflows/pr.yml").read_text(encoding="utf-8")

        self.assertIn("    timeout-minutes: 20\n", workflow_job(workflow, "test"))
        for name in ("build-and-test", "darwin-test", "windows-test"):
            self.assertIn(
                "    timeout-minutes: 20\n", workflow_job(pr_workflow, name)
            )

    def test_chocolatey_install_retries_once_with_attempt_diagnostics(self) -> None:
        workflows = [
            (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"),
            (ROOT / ".github/workflows/pr.yml").read_text(encoding="utf-8"),
        ]
        retry_contract = (
            "for attempt in 1 2; do",
            'echo "::group::Chocolatey FPC install attempt ${attempt}/2"',
            "if choco install -y freepascal; then",
            'echo "::error::Chocolatey FPC install failed after 2 attempts',
            'echo "::warning::Chocolatey FPC install attempt 1/2 failed',
            'exit "$install_status"',
        )

        retry_blocks = []
        for workflow in workflows:
            for line in retry_contract:
                self.assertEqual(1, workflow.count(line), line)
            start = workflow.index("          for attempt in 1 2; do\n")
            end = workflow.index("          done\n", start) + len("          done\n")
            retry_blocks.append(workflow[start:end])
        self.assertEqual(retry_blocks[0], retry_blocks[1])

        probe = (
            "set -euo pipefail\n"
            "attempt_count=0\n"
            'succeed_at="$1"\n'
            "choco() {\n"
            "  attempt_count=$((attempt_count + 1))\n"
            '  echo "simulated Chocolatey output ${attempt_count}"\n'
            '  if [ "$attempt_count" -lt "$succeed_at" ]; then return 7; fi\n'
            "}\n"
            + textwrap.dedent(retry_blocks[0])
            + 'echo "attempt-count=${attempt_count}"\n'
        )
        succeeds_on_retry = subprocess.run(
            ["bash", "-c", probe, "retry-probe", "2"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, succeeds_on_retry.returncode, succeeds_on_retry.stderr)
        self.assertIn("attempt-count=2", succeeds_on_retry.stdout)
        self.assertIn("attempt 1/2 failed", succeeds_on_retry.stdout)
        self.assertIn("attempt 2/2", succeeds_on_retry.stdout)

        both_fail = subprocess.run(
            ["bash", "-c", probe, "retry-probe", "3"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(7, both_fail.returncode)
        self.assertIn("simulated Chocolatey output 1", both_fail.stdout)
        self.assertIn("simulated Chocolatey output 2", both_fail.stdout)
        self.assertIn("failed after 2 attempts (exit code 7)", both_fail.stdout)

    def test_scheduling_diagnostic_accepts_final_interval_completion(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            (tmp / "build").mkdir()
            (tmp / "bin").mkdir()
            fake = tmp / "build/lwpt"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "echo $$ > \"$RUNNER_TEMP/fake-lwpt.pid\"\n"
                "while [ ! -f \"$RUNNER_TEMP/release-lwpt\" ]; do\n"
                "  /bin/sleep 0.01\n"
                "done\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            controlled_sleep = tmp / "bin/sleep"
            controlled_sleep.write_text(
                "#!/usr/bin/env bash\n"
                "touch \"$RUNNER_TEMP/release-lwpt\"\n"
                "while [ ! -s \"$RUNNER_TEMP/fake-lwpt.pid\" ]; do\n"
                "  /bin/sleep 0.01\n"
                "done\n"
                "pid=$(cat \"$RUNNER_TEMP/fake-lwpt.pid\")\n"
                "while kill -0 \"$pid\" 2>/dev/null; do\n"
                "  state=$(ps -p \"$pid\" -o stat= 2>/dev/null || true)\n"
                "  case \"$state\" in *Z*) break ;; esac\n"
                "  /bin/sleep 0.01\n"
                "done\n",
                encoding="utf-8",
            )
            controlled_sleep.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{tmp / 'bin'}:{env['PATH']}",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS": "1",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT": "1",
                    "RUNNER_TEMP": raw_tmp,
                }
            )
            result = subprocess.run(
                [str(ROOT / ".github/delivery/scheduling-diagnostic.sh")],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertNotIn("exceeded", result.stdout)

    def test_scheduling_diagnostic_timeout_reaps_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            (tmp / "build").mkdir()
            child = tmp / "TestScheduling.Test"
            grandchild = tmp / "unrelated-grandchild"
            grandchild.write_text(
                "#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8"
            )
            grandchild.chmod(0o755)
            child.write_text(
                "#!/usr/bin/env bash\n"
                f"{grandchild} &\n"
                "echo $! > grandchild.pid\n"
                "wait\n",
                encoding="utf-8",
            )
            child.chmod(0o755)
            fake = tmp / "build/lwpt"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                f"{child} &\n"
                "echo $! > child.pid\n"
                "wait\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            sample = tmp / "sample"
            sample.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            sample.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{tmp}:{env['PATH']}",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS": "0.05",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT": "20",
                    "LWPT_SCHEDULING_DIAGNOSTIC_SAMPLE_SECONDS": "0",
                    "LWPT_SCHEDULING_DIAGNOSTIC_CLEANUP_GRACE_SECONDS": "0.05",
                    "RUNNER_TEMP": raw_tmp,
                }
            )
            result = subprocess.run(
                [str(ROOT / ".github/delivery/scheduling-diagnostic.sh")],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("exceeded", result.stdout)
            child_pid = int((tmp / "child.pid").read_text().strip())
            grandchild_pid = int((tmp / "grandchild.pid").read_text().strip())
            time.sleep(0.05)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(grandchild_pid, 0)

    def test_orchestration_policy_pins_every_initial_threshold(self) -> None:
        policy = (ROOT / "ORCHESTRATION.md").read_text(encoding="utf-8")
        for boundary in ("greater than 40%", "greater than 55%", "25th", "at most three"):
            self.assertIn(boundary, policy)
        self.assertIn("fork_turns:none", policy)
        self.assertIn("No token or context intervention may silently downgrade", policy)

    def test_main_ruleset_binds_native_admission_job_to_github_actions(self) -> None:
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

    def test_live_review_adapter_matches_macroscope_check_only_success(self) -> None:
        config = json.loads(
            (ROOT / ".github/delivery/review-automations.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual("macroscope", config["automations"][0]["id"])
        self.assertEqual(
            [], config["automations"][0]["terminal_review_states"]
        )


if __name__ == "__main__":
    unittest.main()
