from __future__ import annotations

import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def task_scripts(configuration: dict, task_names: list[str]) -> list[str]:
    """Return the repository scripts run by the given non-media tasks."""
    scripts = []
    for name in task_names:
        if name == "test:media":
            continue
        run = configuration["tasks"][name]["run"]
        for word in str(run).split():
            path = ROOT / word.strip("'\"[]{},")
            if path.suffix == ".sh" and path.is_file():
                scripts.append(path.read_text())
    return scripts


class MiseToolingContractTests(unittest.TestCase):
    def test_hosted_ci_shell_dependencies_are_managed_by_mise(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        tools = configuration["tools"]

        self.assertIn("ripgrep", tools)
        self.assertIn("shellcheck", tools)
        self.assertIn("yq", tools)

    def test_complete_test_task_runs_native_media_once(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["test"]["run"]
        task_names = [
            step["task"]
            for step in steps
            if isinstance(step, dict) and "task" in step
        ]

        self.assertEqual(1, task_names.count("test:media"))
        for script in task_scripts(configuration, task_names):
            self.assertNotIn("DeviceHubPrivateMedia/Tests/run-tests.sh", script)

    def test_ios_only_package_tests_run_in_the_simulator(self) -> None:
        script = (ROOT / "Scripts" / "test-app.sh").read_text()

        self.assertIn(
            "-only-testing:DeviceHubUITests/DeviceKeyboardReceiverTests", script
        )

    def test_full_ci_verifies_the_packaged_protocol_once(self) -> None:
        script = (ROOT / "ci" / "run_ci.sh").read_text()

        self.assertEqual(1, script.count("run_ci_task protocol:verify"))

    def test_lint_task_delegates_to_atomic_mise_tasks(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["lint"]["run"]
        task_names = [step["task"] for step in steps]

        self.assertEqual(
            [
                "format:check",
                "lint:swift",
                "lint:shell",
                "lint:duplication",
                "generate",
                "lint:dead-code",
            ],
            task_names,
        )

    def test_protocol_build_delegates_to_atomic_mise_tasks(self) -> None:
        configuration = tomllib.loads((ROOT / "mise.toml").read_text())
        steps = configuration["tasks"]["protocol:build"]["run"]

        self.assertEqual(
            [
                {"task": "protocol:bootstrap"},
                {"task": "protocol:xcframework"},
            ],
            steps,
        )


if __name__ == "__main__":
    unittest.main()
