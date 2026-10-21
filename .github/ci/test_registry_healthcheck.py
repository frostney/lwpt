from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REGISTRY_EXAMPLE = "docs/examples/registry"


class RegistryHealthcheckTests(unittest.TestCase):
    """The example registry image's health check probes its own listener."""

    def run_healthcheck(self, config: str, body: str, ca: str = "") -> tuple[int, list[str]]:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            data = root / "data"
            data.mkdir()
            (data / "registry.toml").write_text(config, encoding="utf-8")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            calls = root / "curl.args"
            (root / "body").write_text(body, encoding="utf-8")
            curl = bin_dir / "curl"
            curl.write_text(
                "#!/bin/sh\n"
                f'printf "%s\\n" "$@" > "{calls}"\n'
                f'cat "{root / "body"}"\n',
                encoding="utf-8",
            )
            curl.chmod(0o755)
            env = {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "LWPT_REGISTRY_DATA": str(data),
            }
            if ca:
                env["LWPT_REGISTRY_HEALTH_CA"] = ca
            outcome = subprocess.run(
                ["sh", str(ROOT / REGISTRY_EXAMPLE / "healthcheck.sh")],
                env=env, capture_output=True, text=True, timeout=10, check=False,
            )
            args = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
            return outcome.returncode, args

    def test_healthcheck_probes_the_local_listener_under_the_base_url(self) -> None:
        config = (
            'schema = "lwpt-registry-origin-config-v1"\n'
            'identity = "https://registry.example.com"\n'
            'base_url = "https://registry.example.com"\n'
            'listen_address = "0.0.0.0"\n'
            "port = 8443\n"
            'tls_pkcs12 = "/run/secrets/registry.p12"\n'
            'tls_password_env = "LWPT_REGISTRY_TLS_PASSWORD"\n'
        )
        discovery = (
            'schema = "lwpt-registry-discovery-v1"\nprotocol = 1\n'
            'origin = "https://registry.example.com"\n'
            'base_url = "https://registry.example.com"\n'
        )
        status, args = self.run_healthcheck(config, discovery, "/run/secrets/ca.pem")
        self.assertEqual(0, status)
        self.assertIn("::127.0.0.1:8443", args)
        self.assertEqual("https://registry.example.com/.well-known/lwpt-registry", args[-1])
        self.assertEqual("/run/secrets/ca.pem", args[args.index("--cacert") + 1])
        # Another registry answering on the port is not this one.
        other = discovery.replace("registry.example.com", "other.example.com")
        self.assertNotEqual(0, self.run_healthcheck(config, other)[0])
        # A specific listener address is probed directly.
        _, args = self.run_healthcheck(
            config.replace('"0.0.0.0"', '"10.0.0.5"'), discovery
        )
        self.assertIn("::10.0.0.5:8443", args)
        self.assertNotIn("--cacert", args)
        self.assertNotEqual(0, self.run_healthcheck("schema = \"x\"\n", discovery)[0])


if __name__ == "__main__":
    unittest.main()
