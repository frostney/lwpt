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
        self.assertIn("actions: write", watchdog)
        self.assertIn("Reconcile managed delivery and orphaned proofs", watchdog)
        self.assertIn("controller.py observe", watchdog)
        self.assertLess(
            watchdog.index("controller.py watchdog"),
            watchdog.index("controller.py observe"),
        )
        self.assertIn("def recover_completed_full_ci", controller)
        self.assertIn('"ci.yml", created_after, now', controller)

    def test_delivery_observer_omits_no_op_pr_events_and_duplicate_schedule(self) -> None:
        observer = (
            ROOT / ".github/workflows/delivery-observer.yml"
        ).read_text(encoding="utf-8")
        pull_request_types = observer.split("  pull_request_review:", 1)[0]

        self.assertNotIn("      - opened\n", pull_request_types)
        self.assertNotIn("      - ready_for_review\n", pull_request_types)
        self.assertNotIn("  schedule:\n", observer)
        for action in (
            "reopened",
            "synchronize",
            "edited",
            "labeled",
            "unlabeled",
            "converted_to_draft",
            "closed",
        ):
            self.assertIn(f"      - {action}\n", pull_request_types)

    def test_diagnostics_are_allow_listed_and_proof_separated(self) -> None:
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        for value in (
            "x86_64-darwin",
            "x86_64-linux",
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
        self.assertIn('"source/*.Test.pas"', diagnostic)
        self.assertIn('"packages/*/source/*.Test.pas"', diagnostic)
        self.assertIn('"tests/integration/*.Test.pas"', diagnostic)
        self.assertIn("--jobs=1 --bail=1 --verbose", diagnostic)
        self.assertIn('"${test_command[@]}"', diagnostic)
        self.assertIn("diagnostic/", workflow)
        self.assertIn("- diagnostic", workflow)
        self.assertIn("current same-repository PR head", workflow)
        self.assertIn("x86_64-linux/scheduling", workflow)
        self.assertNotIn("x86_64-linux/default", workflow)
        self.assertNotIn("diagnostic:v1", workflow)

    def test_test_routes_use_project_selectors_without_runner_tiers(self) -> None:
        pr_workflow = (ROOT / ".github/workflows/pr.yml").read_text(encoding="utf-8")
        ci_workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        for workflow in (pr_workflow, ci_workflow):
            self.assertNotIn("--tier", workflow)
            self.assertIn("'source/*.Test.pas'", workflow)
            self.assertIn("'packages/*/source/*.Test.pas'", workflow)
            self.assertIn("'tests/integration/*.Test.pas'", workflow)
            self.assertIn("'tests/e2e/*.Test.pas'", workflow)
            self.assertIn("'packages/*/tests/e2e/*.Test.pas'", workflow)
        self.assertIn('LWPT_ENABLE_NETWORK: "1"', pr_workflow)
        self.assertIn('LWPT_ENABLE_NETWORK: "1"', ci_workflow)

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
            "choco install -y freepascal || install_status=$?",
            'if [ "$install_status" -eq 0 ] && [ -n "$FPC_BIN" ]; then',
            'echo "::error::Chocolatey FPC install failed after 2 attempts',
            'echo "::warning::Chocolatey FPC install attempt 1/2 did not produce a usable compiler',
            'exit "$install_status"',
        )

        retry_blocks = []
        for workflow in workflows:
            for line in retry_contract:
                self.assertEqual(1, workflow.count(line), line)
            start = workflow.index("          for attempt in 1 2; do\n")
            end = workflow.index('          echo "Using FPC at $FPC_BIN"\n', start)
            retry_blocks.append(workflow[start:end])
        self.assertEqual(retry_blocks[0], retry_blocks[1])

        probe = (
            "set -euo pipefail\n"
            "attempt_count=0\n"
            'command_succeed_at="$1"\n'
            'artifact_appears_at="$2"\n'
            "choco() {\n"
            "  attempt_count=$((attempt_count + 1))\n"
            '  echo "simulated Chocolatey output ${attempt_count}"\n'
            '  if [ "$attempt_count" -lt "$command_succeed_at" ]; then return 7; fi\n'
            "}\n"
            "find() {\n"
            '  if [ "$attempt_count" -ge "$artifact_appears_at" ]; then\n'
            '    echo "/c/fpc/bin/fpc.exe"\n'
            "  fi\n"
            "}\n"
            + textwrap.dedent(retry_blocks[0]).replace(
                "/c/tools/freepascal /c/fpc", '"."'
            )
            + 'echo "attempt-count=${attempt_count}"\n'
        )
        succeeds_on_retry = subprocess.run(
            ["bash", "-c", probe, "retry-probe", "2", "2"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, succeeds_on_retry.returncode, succeeds_on_retry.stderr)
        self.assertIn("attempt-count=2", succeeds_on_retry.stdout)
        self.assertIn("attempt 1/2 did not produce", succeeds_on_retry.stdout)
        self.assertIn("attempt 2/2", succeeds_on_retry.stdout)

        false_success_retries = subprocess.run(
            ["bash", "-c", probe, "retry-probe", "1", "2"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(
            0, false_success_retries.returncode, false_success_retries.stderr
        )
        self.assertIn("attempt-count=2", false_success_retries.stdout)
        self.assertIn("fpc.exe not found", false_success_retries.stdout)
        self.assertIn("attempt 2/2", false_success_retries.stdout)

        both_fail = subprocess.run(
            ["bash", "-c", probe, "retry-probe", "3", "3"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(7, both_fail.returncode)
        self.assertIn("simulated Chocolatey output 1", both_fail.stdout)
        self.assertIn("simulated Chocolatey output 2", both_fail.stdout)
        self.assertIn(
            "failed after 2 attempts (exit code 7; fpc.exe not found)",
            both_fail.stdout,
        )

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

    def test_active_case_marker_is_published_by_atomic_replacement(self) -> None:
        testing_library = (
            ROOT / "packages/testing/source/TestingPascalLibrary.pas"
        ).read_text(encoding="utf-8")
        publish_start = testing_library.index("procedure PublishActiveTestCase")
        publish_end = testing_library.index(
            "function TestResultToExitCode", publish_start
        )
        publish = testing_library[publish_start:publish_end]
        self.assertIn(".tmp-", publish)
        self.assertLess(
            publish.index("Flush(MarkerFile)"), publish.index("CloseFile")
        )
        self.assertLess(
            publish.index("CloseFile"), publish.index("ReplaceActiveTestCaseFile")
        )
        self.assertIn("RenameFile(ATemporaryPath, ATargetPath)", testing_library)
        self.assertIn("MOVEFILE_REPLACE_EXISTING", testing_library)

    def test_scheduling_diagnostic_timeout_reaps_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            (tmp / "build").mkdir()
            child = tmp / "TestScheduling.Test"
            grandchild = tmp / "unrelated-grandchild"
            grandchild.write_text(
                "#!/usr/bin/env bash\n"
                "proc_dir=\"$LWPT_SCHEDULING_DIAGNOSTIC_PROC_ROOT/$$\"\n"
                "mkdir -p \"$proc_dir/task/$$/fd\"\n"
                "printf 'Name:\\tfixture-grandchild\\nState:\\tS (sleeping)\\n' > \"$proc_dir/status\"\n"
                "printf 'fixture_wait\\n' > \"$proc_dir/wchan\"\n"
                "printf 'read(0x3, 0x4, 0x5)\\n' > \"$proc_dir/syscall\"\n"
                "printf 'fixture-grandchild\\n' > \"$proc_dir/task/$$/comm\"\n"
                "printf 'fixture_task_wait\\n' > \"$proc_dir/task/$$/wchan\"\n"
                "printf 'futex(0x1)\\n' > \"$proc_dir/task/$$/syscall\"\n"
                "printf 'fixture stack\\n' > \"$proc_dir/task/$$/stack\"\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            grandchild.chmod(0o755)
            child.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'TSchedulingSuite > blocked nested case\\n' > \"${TESTING_PASCAL_LIBRARY_ACTIVE_CASE_FILE:-$RUNNER_TEMP/missing-case}\"\n"
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
            timeout = tmp / "timeout"
            timeout.write_text(
                "#!/usr/bin/env bash\nshift\nexec \"$@\"\n", encoding="utf-8"
            )
            timeout.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{tmp}:{env['PATH']}",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS": "0.05",
                    "LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT": "20",
                    "LWPT_SCHEDULING_DIAGNOSTIC_SAMPLE_SECONDS": "0",
                    "LWPT_SCHEDULING_DIAGNOSTIC_CLEANUP_GRACE_SECONDS": "0.05",
                    "LWPT_SCHEDULING_DIAGNOSTIC_PLATFORM": "Linux",
                    "LWPT_SCHEDULING_DIAGNOSTIC_PROC_ROOT": str(tmp / "proc"),
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
            self.assertIn("active test case", result.stdout)
            self.assertIn(
                "TSchedulingSuite > blocked nested case", result.stdout
            )
            self.assertIn("fixture_wait", result.stdout)
            self.assertIn("read(0x3, 0x4, 0x5)", result.stdout)
            self.assertIn("fixture_task_wait", result.stdout)
            self.assertIn("fixture stack", result.stdout)
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

    def test_live_review_adapter_accepts_only_the_exact_macroscope_no_code_skip(self) -> None:
        config = json.loads(
            (ROOT / ".github/delivery/review-automations.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual("macroscope", config["automations"][0]["id"])
        self.assertEqual(
            [], config["automations"][0]["terminal_review_states"]
        )
        self.assertEqual(
            ["success", "neutral"],
            config["automations"][0]["terminal_check_conclusions"],
        )
        self.assertEqual(
            ["No code objects were reviewed."],
            config["automations"][0]["terminal_skipped_output_titles"],
        )


if __name__ == "__main__":
    unittest.main()
