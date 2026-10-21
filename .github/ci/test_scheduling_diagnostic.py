from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CI_TOOLING = ROOT / ".github/ci"


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


if __name__ == "__main__":
    unittest.main()
