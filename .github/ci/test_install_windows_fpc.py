from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CI_TOOLING = ROOT / ".github/ci"


WINDOWS_FPC_UNIT_DIRS = (
    "rtl",
    "rtl-objpas",
    "rtl-generics",
    "rtl-extra",
    "fcl-base",
    "fcl-process",
    "fcl-net",
    "fcl-json",
    "openssl",
    "paszlib",
    "hash",
)


def fake_windows_compiler(path: Path, target: str, bits: int) -> None:
    """Writes a fake FPC that reports `target` and builds a `bits`-wide probe."""
    path.write_text(
        "#!/usr/bin/env bash\n"
        f"echo \"$*\" >> \"$(dirname \"$0\")/{path.name}.calls\"\n"
        "case \"$*\" in\n"
        "  -iV) echo 3.2.2 ;;\n"
        f"  '-iTO -iTP') printf '{target}\\r\\n' ;;\n"
        "  *probe.pas)\n"
        f"    printf '#!/usr/bin/env bash\\nprintf \"{bits}\\\\r\\\\n\"\\n' > probe.exe\n"
        "    chmod +x probe.exe ;;\n"
        "  *) exit 1 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


class WindowsToolingTests(unittest.TestCase):
    def run_installer(
        self,
        tmp: Path,
        target: str,
        compilers: dict[str, tuple[str, int]],
        unit_targets: tuple[str, ...] = ("i386-win32", "x86_64-win64"),
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        root = tmp / "fpc"
        bin_dir = root / "bin/i386-win32"
        bin_dir.mkdir(parents=True)
        for name, (reported_target, bits) in compilers.items():
            fake_windows_compiler(bin_dir / name, reported_target, bits)
        (bin_dir / "instantfpc.exe").write_text("", encoding="utf-8")
        for unit_target in unit_targets:
            for unit_dir in WINDOWS_FPC_UNIT_DIRS:
                (root / "units" / unit_target / unit_dir).mkdir(parents=True)
        tools = tmp / "tools"
        tools.mkdir()
        (tools / "cygpath").write_text('#!/usr/bin/env bash\necho "$2"\n', encoding="utf-8")
        (tools / "curl").write_text(
            "#!/usr/bin/env bash\n"
            'echo "$*" >> "$RUNNER_TEMP/curl.calls"\n'
            'while [ $# -gt 1 ]; do\n'
            '  if [ "$1" = --output ]; then echo tampered > "$2"; fi\n'
            "  shift\n"
            "done\n",
            encoding="utf-8",
        )
        for tool in tools.iterdir():
            tool.chmod(0o755)
        runner_temp = tmp / "runner"
        runner_temp.mkdir()
        github_env = tmp / "github-env"
        github_path = tmp / "github-path"
        result = subprocess.run(
            [str(CI_TOOLING / "install-windows-fpc.sh"), target],
            env={
                "PATH": f"{tools}:{os.environ['PATH']}",
                "LWPT_WINDOWS_FPC_ROOT": str(root),
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_ENV": str(github_env),
                "GITHUB_PATH": str(github_path),
            },
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        published: dict[str, str] = {}
        if github_env.exists():
            for line in github_env.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition("=")
                published[key] = value
        return result, published

    def test_x86_64_leg_compiles_test_programs_with_the_win64_cross_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            result, published = self.run_installer(
                tmp,
                "x86_64-win64",
                {"fpc.exe": ("win32 i386", 32), "ppcrossx64.exe": ("win64 x86_64", 64)},
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            root = tmp / "fpc"
            self.assertEqual(str(root / "bin/i386-win32/ppcrossx64.exe"), published["LWPT_FPC"])
            self.assertEqual(
                str(root / "bin/i386-win32/instantfpc.exe"), published["LWPT_INSTANTFPC"]
            )
            self.assertEqual(
                ";".join(str(root / "units/x86_64-win64" / d) for d in WINDOWS_FPC_UNIT_DIRS),
                published["LWPT_FPC_UNIT_PATHS"],
            )
            self.assertNotIn("i386-win32", published["LWPT_FPC_UNIT_PATHS"])
            self.assertIn("-l probe.pas", (root / "bin/i386-win32/ppcrossx64.exe.calls").read_text())
            self.assertIn("x86_64-win64 test programs compile as 64-bit images", result.stdout)
            self.assertFalse((tmp / "runner/curl.calls").exists())

    def test_i386_leg_keeps_the_native_i386_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            result, published = self.run_installer(
                tmp, "i386-win32", {"fpc.exe": ("win32 i386", 32)}, ("i386-win32",)
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            root = tmp / "fpc"
            self.assertEqual(str(root / "bin/i386-win32/fpc.exe"), published["LWPT_FPC"])
            self.assertEqual(
                ";".join(str(root / "units/i386-win32" / d) for d in WINDOWS_FPC_UNIT_DIRS),
                published["LWPT_FPC_UNIT_PATHS"],
            )
            self.assertIn("i386-win32 test programs compile as 32-bit images", result.stdout)
            self.assertFalse((tmp / "runner/curl.calls").exists())

    def test_windows_setup_rejects_a_compiler_for_another_target(self) -> None:
        cases = (
            ("x86_64-win64", {"fpc.exe": ("win32 i386", 32), "ppcrossx64.exe": ("win32 i386", 32)}),
            ("x86_64-win64", {"fpc.exe": ("win32 i386", 32), "ppcrossx64.exe": ("win64 x86_64", 32)}),
            ("i386-win32", {"fpc.exe": ("win64 x86_64", 64)}),
        )
        for target, compilers in cases:
            with self.subTest(target=target, compilers=compilers):
                with tempfile.TemporaryDirectory() as raw_tmp:
                    result, _ = self.run_installer(Path(raw_tmp), target, compilers)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("::error::", result.stdout)

    def test_windows_setup_requires_units_for_the_requested_target(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            result, _ = self.run_installer(
                Path(raw_tmp),
                "x86_64-win64",
                {"fpc.exe": ("win32 i386", 32), "ppcrossx64.exe": ("win64 x86_64", 64)},
                ("i386-win32",),
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("units/x86_64-win64/rtl", result.stdout)

    def test_missing_cross_compiler_downloads_the_pinned_add_on(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            result, published = self.run_installer(
                tmp, "x86_64-win64", {"fpc.exe": ("win32 i386", 32)}
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("cross add-on checksum mismatch", result.stdout)
            self.assertNotIn("LWPT_FPC", published)
            calls = (tmp / "runner/curl.calls").read_text(encoding="utf-8")
            self.assertIn(
                "https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/"
                "fpc-3.2.2.i386-win32.cross.x86_64-win64.exe",
                calls,
            )

    def test_windows_setup_rejects_unknown_targets(self) -> None:
        for target in ("", "x86_64-linux", "win64"):
            with self.subTest(target=target):
                with tempfile.TemporaryDirectory() as raw_tmp:
                    result, published = self.run_installer(
                        Path(raw_tmp), target, {"fpc.exe": ("win32 i386", 32)}
                    )
                    self.assertEqual(2, result.returncode)
                    self.assertEqual({}, published)


if __name__ == "__main__":
    unittest.main()
