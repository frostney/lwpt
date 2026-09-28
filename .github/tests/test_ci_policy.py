from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CI_TOOLING = ROOT / ".github/ci"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def workflow_job(workflow: str, name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n.*?(?=^  [a-zA-Z0-9_-]+:\n|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"workflow job {name!r} not found")
    return match.group(0)


def workflow_job_names(workflow: str) -> list[str]:
    jobs = workflow.split("\njobs:\n", 1)[1]
    return re.findall(r"^  ([a-zA-Z0-9_-]+):\n", jobs, re.MULTILINE)


class PullRequestGateTests(unittest.TestCase):
    def test_every_base_branch_runs_the_gate(self) -> None:
        workflow = read(".github/workflows/pr.yml")
        trigger = workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("  pull_request:\n", trigger)
        self.assertNotIn("branches:", trigger)
        self.assertNotIn("codex/", workflow)

    def test_gate_has_no_label_routing(self) -> None:
        workflow = read(".github/workflows/pr.yml")
        for retired in ("delivery-gate", "deferred", "delivery:managed", "ci:ready"):
            self.assertNotIn(retired, workflow)
        self.assertIn("cancel-in-progress: true", workflow)

    def test_admission_job_requires_every_native_job(self) -> None:
        workflow = read(".github/workflows/pr.yml")
        admission = workflow_job(workflow, "delivery-admission")
        self.assertIn("if: ${{ always() }}", admission)
        others = [
            name for name in workflow_job_names(workflow)
            if name != "delivery-admission"
        ]
        self.assertEqual(
            [
                "build-and-test",
                "docs",
                "darwin-test",
                "toolchain",
                "windows-cross-compile",
                "windows-test",
            ],
            others,
        )
        for name in others:
            self.assertIn(f"      - {name}\n", admission)
            self.assertIn(f"${{{{ needs.{name}.result }}}}", admission)

    def test_main_ruleset_binds_native_admission_job_to_github_actions(self) -> None:
        ruleset = json.loads(read(".github/rulesets/protect-main.json"))
        pull_rule = next(rule for rule in ruleset["rules"] if rule["type"] == "pull_request")
        self.assertTrue(pull_rule["parameters"]["required_review_thread_resolution"])
        self.assertEqual(["squash"], pull_rule["parameters"]["allowed_merge_methods"])
        status_rule = next(
            rule for rule in ruleset["rules"] if rule["type"] == "required_status_checks"
        )
        self.assertEqual(
            [{"context": "delivery-admission", "integration_id": 15368}],
            status_rule["parameters"]["required_status_checks"],
        )


class IntegratedWorkflowTests(unittest.TestCase):
    def test_dispatch_offers_only_manual_and_diagnostic_modes(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        mode = re.search(
            r"^      mode:\n.*?options:\n((?:          - [^\n]+\n)+)",
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(mode)
        self.assertEqual(
            ["manual", "diagnostic"],
            re.findall(r"- (\S+)", mode.group(1)),
        )
        for retired in (
            "full-ci",
            "candidate_pr_number",
            "expected_head",
            "topology_digest",
            "check_id",
            "gh api",
        ):
            self.assertNotIn(retired, workflow)

    def test_run_name_shows_mode_and_ref(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        run_name = workflow.split("\non:\n", 1)[0]
        self.assertIn("github.ref_name", run_name)
        self.assertIn("inputs.mode || github.event_name", run_name)
        self.assertIn("inputs.diagnostic_target", run_name)

    def test_runs_check_out_the_dispatched_head(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        refs = re.findall(r"^          ref: (.+)$", workflow, re.MULTILINE)
        self.assertEqual(["${{ github.sha }}", "${{ github.sha }}"], refs)

    def test_diagnostics_are_allow_listed_slices(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        for value in (
            "aarch64-darwin",
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
        self.assertIn("x86_64-linux/scheduling", workflow)
        self.assertIn("aarch64-darwin/scheduling", workflow)
        self.assertNotIn("aarch64-darwin/default", workflow)
        self.assertNotIn("x86_64-linux/default", workflow)
        self.assertIn("run: .github/ci/scheduling-diagnostic.sh", workflow)
        self.assertIn("format('diagnostic-{0}', github.ref_name)", workflow)

        diagnostic = (CI_TOOLING / "scheduling-diagnostic.sh").read_text(encoding="utf-8")
        self.assertIn("TestScheduling.Test.pas", diagnostic)
        self.assertIn("diagnostic exceeded its bounded runtime", diagnostic)
        self.assertIn('"source/*.Test.pas"', diagnostic)
        self.assertIn('"packages/*/source/*.Test.pas"', diagnostic)
        self.assertIn('"tests/integration/*.Test.pas"', diagnostic)
        self.assertIn("--jobs=1 --bail=1 --verbose", diagnostic)
        self.assertIn('"${test_command[@]}"', diagnostic)

    def test_arm_darwin_scheduling_diagnostic_uses_native_matrix(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        self.assertIn(
            'BUILD=\'{"include":[{"target":"aarch64-darwin","cpu":"aarch64",'
            '"os":"darwin","native":true}]}\'',
            workflow,
        )
        self.assertIn(
            'TEST=\'{"include":[{"target":"aarch64-darwin",'
            '"runner":"macos-latest","fpc-install":"brew"}]}\'',
            workflow,
        )

    def test_scheduling_diagnostic_has_realistic_hosted_budget(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        diagnostic = (CI_TOOLING / "scheduling-diagnostic.sh").read_text(encoding="utf-8")
        script_poll_seconds = re.search(
            r'poll_seconds="\$\{LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS:-(\d+)\}"',
            diagnostic,
        )
        script_poll_count = re.search(
            r'poll_count="\$\{LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT:-(\d+)\}"',
            diagnostic,
        )
        workflow_poll_counts = re.search(
            r"diagnostic_selector == 'default' && '(\d+)' \|\| "
            r"\(inputs\.diagnostic_target == 'x86_64-darwin' \|\| "
            r"inputs\.diagnostic_target == 'aarch64-darwin'\) && '(\d+)' "
            r"\|\| '(\d+)'",
            workflow,
        )
        self.assertIsNotNone(script_poll_seconds)
        self.assertIsNotNone(script_poll_count)
        self.assertIsNotNone(workflow_poll_counts)
        scheduling_poll_seconds = int(script_poll_seconds.group(1))
        scheduling_poll_count = int(script_poll_count.group(1))
        default_poll_count = int(workflow_poll_counts.group(1))
        darwin_poll_count = int(workflow_poll_counts.group(2))
        linux_poll_count = int(workflow_poll_counts.group(3))
        self.assertEqual(30, scheduling_poll_count)
        self.assertEqual(84, default_poll_count)
        self.assertEqual(scheduling_poll_count, darwin_poll_count)
        self.assertEqual(18, linux_poll_count)
        # The focused suite was still making progress at 90.072 seconds on
        # macos-15-intel. Keep approximately one minute beyond that observed
        # lower bound.
        self.assertGreaterEqual(scheduling_poll_seconds * darwin_poll_count, 150)
        self.assertEqual(420, scheduling_poll_seconds * default_poll_count)
        self.assertEqual(90, scheduling_poll_seconds * linux_poll_count)

    def test_test_routes_use_project_selectors_without_runner_tiers(self) -> None:
        for workflow in (read(".github/workflows/pr.yml"), read(".github/workflows/ci.yml")):
            self.assertNotIn("--tier", workflow)
            self.assertIn("'source/*.Test.pas'", workflow)
            self.assertIn("'packages/*/source/*.Test.pas'", workflow)
            self.assertIn("'tests/integration/*.Test.pas'", workflow)
            self.assertIn("'tests/e2e/*.Test.pas'", workflow)
            self.assertIn("'packages/*/tests/e2e/*.Test.pas'", workflow)
            self.assertIn('LWPT_ENABLE_NETWORK: "1"', workflow)

    def test_native_test_jobs_have_twenty_minute_timeout(self) -> None:
        workflow = read(".github/workflows/ci.yml")
        pr_workflow = read(".github/workflows/pr.yml")
        self.assertIn("    timeout-minutes: 20\n", workflow_job(workflow, "test"))
        for name in ("build-and-test", "darwin-test", "windows-test"):
            self.assertIn("    timeout-minutes: 20\n", workflow_job(pr_workflow, name))


class WindowsToolingTests(unittest.TestCase):
    def test_windows_compiler_setup_publishes_required_paths(self) -> None:
        installer = (CI_TOOLING / "install-windows-fpc.sh").read_text(encoding="utf-8")
        self.assertIn('fpc_bin="${install_root}/bin/i386-win32/fpc.exe"', installer)
        self.assertIn('echo "LWPT_FPC=$LWPT_FPC_VALUE"', installer)
        self.assertIn('head -1 || true)\nif [ -n "${instantfpc_bin}" ]', installer)
        self.assertIn("for unit_target in i386-win32 x86_64-win64", installer)
        self.assertIn('"${fpc_bin}" -iV', installer)

    def test_windows_fpc_uses_pinned_official_distribution(self) -> None:
        for name in ("ci.yml", "pr.yml"):
            workflow = read(f".github/workflows/{name}")
            self.assertEqual(1, workflow.count(".github/ci/install-windows-fpc.sh"))
            self.assertNotIn("choco install -y freepascal", workflow)
            self.assertNotIn('"fpc-install":"choco"', workflow)

        installer_path = CI_TOOLING / "install-windows-fpc.sh"
        installer = installer_path.read_text(encoding="utf-8")
        self.assertTrue(os.access(installer_path, os.X_OK))
        self.assertIn(
            "https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/"
            "fpc-3.2.2.i386-win32.exe",
            installer,
        )
        self.assertIn(
            "7ec78b1790ecac7685f440b17f9e03865bc09846b7c068a9270c4d37704b5ac8",
            installer,
        )
        self.assertIn("--retry 2", installer)
        self.assertIn("--retry-max-time 240", installer)
        self.assertIn("--max-time 120", installer)
        self.assertIn("sha256sum", installer)
        self.assertIn("/VERYSILENT", installer)


class SchedulingDiagnosticTests(unittest.TestCase):
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
                [str(CI_TOOLING / "scheduling-diagnostic.sh")],
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
        testing_library = read("packages/testing/source/TestingPascalLibrary.pas")
        publish_start = testing_library.index("procedure PublishActiveTestCase")
        publish_end = testing_library.index("function TestResultToExitCode", publish_start)
        publish = testing_library[publish_start:publish_end]
        self.assertIn(".tmp-", publish)
        self.assertLess(publish.index("Flush(MarkerFile)"), publish.index("CloseFile"))
        self.assertLess(publish.index("CloseFile"), publish.index("ReplaceActiveTestCaseFile"))
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
            timeout.write_text("#!/usr/bin/env bash\nshift\nexec \"$@\"\n", encoding="utf-8")
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
                [str(CI_TOOLING / "scheduling-diagnostic.sh")],
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
            self.assertIn("TSchedulingSuite > blocked nested case", result.stdout)
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


class OrchestrationPolicyTests(unittest.TestCase):
    def test_policy_declares_the_sections_milestone_rush_requires(self) -> None:
        policy = read("ORCHESTRATION.md")
        for heading in (
            "## Capability classes and routing",
            "## Context packets",
            "## Token checkpoints and interventions",
            "## Monitoring and waits",
            "## Escalation",
            "## Lane-admission preflight",
            "## Integration and merge",
        ):
            self.assertIn(heading, policy)
        for boundary in ("greater than 40%", "greater than 55%", "25th", "at most three"):
            self.assertIn(boundary, policy)

    def test_policy_binds_repository_evidence(self) -> None:
        policy = read("ORCHESTRATION.md")
        self.assertIn("`delivery-admission`", policy)
        self.assertIn("every pr also needs a green", policy.replace("\n", " ").lower())
        self.assertIn("gh workflow run ci.yml --ref <branch> -f mode=manual", policy)
        self.assertIn("--match-head-commit", policy)
        self.assertIn("`.github/delivery/review-automations.json`", policy)
        self.assertIn("## Review evidence", policy)
        self.assertIn("`gpt-6-astra`", policy)
        self.assertIn("CodeRabbit is advisory", policy)
        self.assertTrue((ROOT / ".github/delivery/review-automations.json").is_file())
        for retired in ("delivery-transition", "merge:ready", "review:ready", "delivery:managed",
                        "ci:full-required"):
            self.assertNotIn(retired, policy)

    def test_path_budget_fits_the_deepest_measured_path(self) -> None:
        policy = read("ORCHESTRATION.md")
        budget = re.search(r"wc -c\)\" -le (\d+)", policy)
        self.assertIsNotNone(budget)
        deepest = re.search(r"(\d+) characters below the root", policy)
        self.assertIsNotNone(deepest)
        limit = re.search(
            r"COMPILER_PATH_LIMIT = (\d+);", read("source/LWPT.BuildSession.pas")
        )
        self.assertIsNotNone(limit)
        self.assertEqual("255", limit.group(1))
        self.assertLessEqual(
            int(budget.group(1)) + int(deepest.group(1)), int(limit.group(1))
        )


class ReviewPolicyTests(unittest.TestCase):
    """The shape address-feedback's review_wait.py accepts as its default policy."""

    LIST_FIELDS = (
        "actors",
        "check_contexts",
        "check_app_slugs",
        "terminal_check_conclusions",
        "terminal_review_states",
        "nonterminal_review_markers",
    )

    def test_review_automations_match_the_address_feedback_policy_shape(self) -> None:
        policy = json.loads(read(".github/delivery/review-automations.json"))
        self.assertIsInstance(policy, dict)
        automations = policy["automations"]
        self.assertIsInstance(automations, list)
        for automation in automations:
            self.assertIsInstance(automation, dict)
            self.assertIsInstance(automation.get("id"), str)
            for field in self.LIST_FIELDS:
                values = automation.get(field, [])
                self.assertIsInstance(values, list, field)
                self.assertTrue(all(isinstance(value, str) for value in values), field)
            self.assertTrue(
                automation.get("check_contexts") or automation.get("terminal_review_states"),
                f"{automation['id']} has no terminal evidence",
            )

    def test_no_hosted_automation_gates_review(self) -> None:
        # Review evidence is the agent-run independent review (ORCHESTRATION.md);
        # CodeRabbit is advisory and Macroscope is retired.
        policy = json.loads(read(".github/delivery/review-automations.json"))
        self.assertEqual([], policy["automations"])


class RetiredMachineryTests(unittest.TestCase):
    def test_managed_delivery_machinery_is_gone(self) -> None:
        for path in (
            ".github/workflows/delivery-transition.yml",
            ".github/workflows/delivery-observer.yml",
            ".github/workflows/delivery-finalizer.yml",
            ".github/workflows/delivery-watchdog.yml",
            ".github/delivery/controller.py",
            ".github/delivery/model.py",
            ".github/delivery/tests",
        ):
            self.assertFalse((ROOT / path).exists(), path)
        self.assertEqual(
            ["review-automations.json"],
            sorted(item.name for item in (ROOT / ".github/delivery").iterdir()),
        )


if __name__ == "__main__":
    unittest.main()
