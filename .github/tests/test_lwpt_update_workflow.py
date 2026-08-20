from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github/workflows/lwpt-update.yml"


def step_script(workflow: str, name: str) -> str:
    step = re.search(
        rf"^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - |\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if step is None:
        raise AssertionError(f"workflow step {name!r} not found")
    run = re.search(
        r"^        run: \|\n(?P<body>.*)\Z",
        step.group("body"),
        re.MULTILINE | re.DOTALL,
    )
    if run is None:
        raise AssertionError(f"workflow step {name!r} has no block script")
    return textwrap.dedent(run.group("body"))


def embedded_python(script: str) -> str:
    marker = "python3 - <<'PY'\n"
    start = script.index(marker) + len(marker)
    end = script.index("\nPY\n", start)
    return script[start:end]


class LWPTUpdateWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_reusable_contract_is_bounded_and_token_override_is_optional(self) -> None:
        workflow = self.workflow
        for expected in (
            "workflow_call:",
            "workflow_dispatch:",
            "working-directory:",
            "branch-name:",
            "pr-title:",
            "lwpt-ref:",
            "update_token:",
            "contents: write",
            "pull-requests: write",
            "cancel-in-progress: false",
            "secrets.update_token || github.token",
            "timeout-minutes: 30",
        ):
            self.assertIn(expected, workflow)
        self.assertIn("git push --force-with-lease", workflow)
        self.assertIn('if [ "$BRANCH_NAME" = "$default_branch" ]', workflow)
        self.assertNotIn("git add -A -- lwpt.toml lwpt.lock lwpt.cfg .lwpt || true", workflow)
        self.assertEqual(1, workflow.count("output.write(f'pending={len(pending)}\\n')"))

    def test_scan_accepts_only_the_documented_statuses_and_writes_one_output(self) -> None:
        code = embedded_python(step_script(self.workflow, "Scan and update"))
        report = {
            "packages": [
                {"name": "current", "locked": "1.0.0", "latest": "1.0.0", "status": "current"},
                {"name": "newer", "locked": "1.0.0", "latest": "1.1.0", "status": "newer"},
                {"name": "major", "locked": "1.1.0", "latest": "2.0.0", "status": "major"},
            ]
        }
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            outdated = tmp / "outdated.json"
            pending = tmp / "pending.json"
            output = tmp / "output"
            outdated.write_text(json.dumps(report), encoding="utf-8")
            env = os.environ.copy()
            env.update(
                {
                    "LWPT_OUTDATED_JSON": str(outdated),
                    "LWPT_PENDING_JSON": str(pending),
                    "LWPT_SCAN_EXIT": "1",
                    "GITHUB_OUTPUT": str(output),
                }
            )
            result = subprocess.run(
                ["python3", "-c", code],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(["newer", "major"], [p["name"] for p in json.loads(pending.read_text())])
            self.assertEqual("pending=2\n", output.read_text())
            self.assertIn("Compared 3 git-host dependencies; 2 pending.", result.stdout)

            report["packages"] = [
                {"name": "current", "locked": "1.0.0", "latest": "1.0.0", "status": "current"}
            ]
            outdated.write_text(json.dumps(report), encoding="utf-8")
            output.write_text("", encoding="utf-8")
            env["LWPT_SCAN_EXIT"] = "0"
            current = subprocess.run(
                ["python3", "-c", code],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, current.returncode, current.stderr)
            self.assertEqual([], json.loads(pending.read_text()))
            self.assertEqual("pending=0\n", output.read_text())

            report["packages"][0]["status"] = "unknown"
            outdated.write_text(json.dumps(report), encoding="utf-8")
            invalid = subprocess.run(
                ["python3", "-c", code],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(0, invalid.returncode)
            self.assertIn("invalid package status", invalid.stderr)

    def test_pr_body_keeps_release_markdown_literal_and_skips_non_github_hosts(self) -> None:
        code = embedded_python(step_script(self.workflow, "Build pull-request body"))
        packages = [
            {
                "name": "leaf",
                "source": "acme/leaf",
                "locator": "acme/leaf",
                "constraint": "^1.2.0",
                "locked": "1.2.0",
                "latest": "`2.0.0`**@team**`",
                "latestRef": "v2.0.0",
                "status": "major",
            },
            {
                "name": "forge",
                "source": "gitlab:acme/forge",
                "locator": "acme/forge",
                "constraint": "~0.3.0",
                "locked": "0.3.1",
                "latest": "0.4.0",
                "latestRef": "v0.4.0",
                "status": "major",
            },
            {
                "name": "custom",
                "source": "internal:acme/custom",
                "locator": "acme/custom",
                "constraint": "1.0.0",
                "locked": "1.0.0",
                "latest": "1.1.0",
                "latestRef": "v1.1.0",
                "status": "newer",
            },
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            pending = tmp / "pending.json"
            body_path = tmp / "body.md"
            calls = tmp / "gh-calls"
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            pending.write_text(json.dumps(packages), encoding="utf-8")
            fake_gh = bin_dir / "gh"
            fake_gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "with pathlib.Path(os.environ['GH_CALLS']).open('a') as output:\n"
                "    output.write(' '.join(sys.argv[1:]) + '\\n')\n"
                "print(json.dumps({\n"
                "    'name': 'Release @team #42 [breaking]',\n"
                "    'tag_name': 'v2.0.0',\n"
                "    'body': '## Changes\\n\\nFixes #42\\nThanks @maintainer\\n\\n```danger\\n</details>',\n"
                "}))\n",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "GH_CALLS": str(calls),
                    "LWPT_PENDING_JSON": str(pending),
                    "LWPT_PR_BODY": str(body_path),
                }
            )
            result = subprocess.run(
                ["python3", "-c", code],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            body = body_path.read_text(encoding="utf-8")
            self.assertIn(
                "| `leaf` | `^1.2.0` | `1.2.0` | `` `2.0.0`**@team**` `` | major |",
                body,
            )
            self.assertIn("Release &#64;team &#35;42 \\[breaking\\]", body)
            self.assertIn("````text\n## Changes", body)
            self.assertIn("Fixes #42\nThanks @maintainer", body)
            self.assertIn("</details>\n````", body)
            self.assertIn("Hosted outside GitHub (`gitlab:acme/forge`)", body)
            self.assertIn("Hosted outside GitHub (`internal:acme/custom`)", body)
            self.assertEqual(1, len(calls.read_text(encoding="utf-8").splitlines()))


if __name__ == "__main__":
    unittest.main()
