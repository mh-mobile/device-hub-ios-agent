from __future__ import annotations

import subprocess
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MISE_PATH = ROOT / "mise.toml"
CI_PATH = ROOT / "ci" / "run_ci.sh"


class CILocalGateContractTests(unittest.TestCase):
    def test_repository_owns_one_canonical_ci_task(self) -> None:
        config = tomllib.loads(MISE_PATH.read_text())

        self.assertEqual("ci/run_ci.sh", config["tasks"]["ci"]["run"])
        self.assertFalse((ROOT / ".github" / "workflows" / "ci.yml").exists())

    def test_ci_runs_every_test_lint_preview_and_release_build_gate(self) -> None:
        source = CI_PATH.read_text()

        for command in (
            "run_ci_task test",
            "run_ci_task protocol:verify",
            "run_ci_task lint",
            "run_ci_task previews",
            "run_ci_task build",
        ):
            with self.subTest(command=command):
                self.assertIn(command, source)

        self.assertIn("CONFIGURATION=Release", source)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", source)
        self.assertIn("DEVICE_HUB_FULL_CI", source)

    def test_signing_material_and_secrets_are_ignored_by_git(self) -> None:
        for name in (
            "Config/Development.mobileprovision",
            "Distribution.p12",
            "AuthKey_ABC123.p8",
            "signing/key.pem",
            ".env",
            ".env.local",
        ):
            with self.subTest(name=name):
                result = subprocess.run(
                    ("git", "check-ignore", "-q", "--no-index", name),
                    cwd=ROOT,
                    check=False,
                )
                self.assertEqual(result.returncode, 0)

    def test_ci_keeps_the_outer_guard_while_nested_mise_tasks_reacquire_their_lock(self) -> None:
        source = CI_PATH.read_text()

        self.assertIn("DEVICE_HUB_GUARD_HELD=0", source)
        self.assertIn("DEVICE_HUB_GUARD_LOCK_PATH", source)

    def test_ci_acquires_one_simulator_lease_before_the_process_guard(self) -> None:
        source = CI_PATH.read_text()

        simulator_index = source.index(
            "devicehub_enter_simulator_lease device-hub-full-ci"
        )
        process_index = source.index("devicehub_require_guard full-ci")
        self.assertLess(simulator_index, process_index)
        self.assertIn("devicehub_require_simulator device-hub-full-ci", source)
        self.assertIn("devicehub_cleanup_simulator", source)

    def test_ci_fails_when_verification_changes_the_checkout(self) -> None:
        source = CI_PATH.read_text()

        snapshot = source.index('CHECKOUT_BEFORE="$(checkout_state)"')
        first_gate = source.index("run_ci_task test")
        comparison = source.index('"$(checkout_state)" != "$CHECKOUT_BEFORE"')
        passed = source.index("Device Hub CI passed")
        self.assertLess(snapshot, first_gate)
        self.assertLess(first_gate, comparison)
        self.assertLess(comparison, passed)


if __name__ == "__main__":
    unittest.main()
