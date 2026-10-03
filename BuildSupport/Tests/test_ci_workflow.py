from __future__ import annotations

import re
import subprocess
import tempfile
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

    def test_checkout_state_sees_a_gate_rewriting_an_untracked_file(self) -> None:
        function = re.search(r"checkout_state\(\) \{.*?\n\}", CI_PATH.read_text(), re.S)
        self.assertIsNotNone(function)
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            for arguments in (
                ("init", "-q"),
                ("-c", "user.email=ci@example.com", "-c", "user.name=CI",
                 "commit", "-q", "--allow-empty", "-m", "base"),
            ):
                subprocess.run(("git", *arguments), cwd=repository, check=True)
            snapshot = repository / "new-scenario.png"
            snapshot.write_text("recorded\n")

            def state() -> str:
                return subprocess.run(
                    ("bash", "-c", f"{function.group(0)}\ncheckout_state"),
                    cwd=repository,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout

            before = state()
            snapshot.write_text("rewritten by a gate\n")

            self.assertNotEqual(before, state())

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
