import subprocess
import tempfile
import unittest
from pathlib import Path

from BuildSupport.ci_scope import changed_paths, is_documentation_only


class CIScopeTests(unittest.TestCase):
    def test_documentation_scope_requires_at_least_one_documentation_change(self):
        self.assertFalse(is_documentation_only([]))
        self.assertTrue(is_documentation_only(["README.md", "Docs/Architecture.md"]))
        self.assertTrue(is_documentation_only(["LICENSE"]))
        self.assertFalse(is_documentation_only(["README.md", "Sources/App.swift"]))

    def test_changed_paths_includes_committed_work_and_worktree_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "work"
            repository.mkdir()
            self.run_git(repository, "init", "-b", "main")
            self.run_git(repository, "config", "user.email", "ci@example.com")
            self.run_git(repository, "config", "user.name", "CI Test")
            self.run_git(repository, "config", "commit.gpgsign", "false")
            (repository / "README.md").write_text("Initial\n")
            self.run_git(repository, "add", "README.md")
            self.run_git(repository, "commit", "-m", "Initial")

            remote = root / "remote.git"
            self.run_git(repository, "init", "--bare", str(remote))
            self.run_git(repository, "remote", "add", "origin", str(remote))
            self.run_git(repository, "push", "-u", "origin", "main")

            (repository / "README.md").write_text("Committed\n")
            self.run_git(repository, "commit", "-am", "Update docs")
            (repository / "Docs").mkdir()
            (repository / "Docs" / "Design.md").write_text("Untracked\n")

            self.assertEqual(
                changed_paths(repository),
                {"README.md", "Docs/Design.md"},
            )

    def test_unpushed_branch_includes_commits_since_the_default_branch(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_pushed_repository(Path(directory))
            self.run_git(repository, "switch", "-c", "feature")
            (repository / "App.swift").write_text("let changed = 1\n")
            self.run_git(repository, "commit", "-am", "Change source")
            (repository / "Notes.md").write_text("Untracked\n")

            self.assertIn("App.swift", changed_paths(repository))
            self.assertFalse(is_documentation_only(changed_paths(repository)))

    def test_pushed_branch_still_compares_against_the_default_branch(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_pushed_repository(Path(directory))
            self.run_git(repository, "switch", "-c", "feature")
            (repository / "App.swift").write_text("let changed = 1\n")
            self.run_git(repository, "commit", "-am", "Change source")
            self.run_git(repository, "push", "-u", "origin", "feature")
            (repository / "Notes.md").write_text("Untracked\n")

            self.assertIn("App.swift", changed_paths(repository))
            self.assertFalse(is_documentation_only(changed_paths(repository)))

    def test_source_renamed_into_docs_is_not_documentation(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_pushed_repository(Path(directory))
            (repository / "Docs").mkdir()
            self.run_git(repository, "mv", "App.swift", "Docs/App.md")
            self.run_git(repository, "commit", "-m", "Move source")

            self.assertIn("App.swift", changed_paths(repository))
            self.assertFalse(is_documentation_only(changed_paths(repository)))

    def test_deleted_source_is_not_documentation(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_pushed_repository(Path(directory))
            self.run_git(repository, "rm", "-q", "App.swift")
            (repository / "README.md").write_text("Edited\n")

            self.assertIn("App.swift", changed_paths(repository))
            self.assertFalse(is_documentation_only(changed_paths(repository)))

    def test_unknown_base_is_never_documentation(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            self.run_git(repository, "init", "-b", "feature")
            self.configure(repository)
            (repository / "App.swift").write_text("let value = 0\n")
            self.run_git(repository, "add", "App.swift")
            self.run_git(repository, "commit", "-m", "Initial")
            (repository / "README.md").write_text("Docs\n")

            self.assertIsNone(changed_paths(repository))
            self.assertFalse(is_documentation_only(changed_paths(repository)))

    def make_pushed_repository(self, root: Path) -> Path:
        repository = root / "work"
        repository.mkdir()
        self.run_git(repository, "init", "-b", "main")
        self.configure(repository)
        (repository / "README.md").write_text("Initial\n")
        (repository / "App.swift").write_text("let value = 0\n")
        self.run_git(repository, "add", ".")
        self.run_git(repository, "commit", "-m", "Initial")
        remote = root / "remote.git"
        self.run_git(repository, "init", "--bare", str(remote))
        self.run_git(repository, "remote", "add", "origin", str(remote))
        self.run_git(repository, "push", "-u", "origin", "main")
        return repository

    def configure(self, repository: Path) -> None:
        self.run_git(repository, "config", "user.email", "ci@example.com")
        self.run_git(repository, "config", "user.name", "CI Test")
        self.run_git(repository, "config", "commit.gpgsign", "false")

    @staticmethod
    def run_git(repository: Path, *arguments: str) -> None:
        subprocess.run(
            ("git", *arguments),
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
