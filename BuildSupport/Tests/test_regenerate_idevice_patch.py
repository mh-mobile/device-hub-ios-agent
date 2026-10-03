from __future__ import annotations

import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bootstrap_idevice
import regenerate_idevice_patch


class RegenerateIdevicePatchTests(unittest.TestCase):
    def test_patch_and_digests_follow_the_edited_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "idevice"
            checkout.mkdir()
            self.git(checkout, "init", "-q", "-b", "main")
            self.git(checkout, "config", "user.email", "ci@example.com")
            self.git(checkout, "config", "user.name", "CI Test")
            self.git(checkout, "config", "commit.gpgsign", "false")
            (checkout / "lib.rs").write_text("fn upstream() {}\n")
            self.git(checkout, "add", ".")
            self.git(checkout, "commit", "-q", "-m", "upstream")
            revision = self.git(checkout, "rev-parse", "HEAD").strip()

            (checkout / "lib.rs").write_text("fn patched() {}\n")
            (checkout / "added.rs").write_text("fn added() {}\n")
            patch = root / "idevice.patch"
            source = root / "bootstrap_idevice.py"
            source.write_text(
                'IDEVICE_PATCH_SHA256 = (\n    "old"\n)\n'
                'IDEVICE_TREE_SHA256 = "old"\n'
            )

            regenerate_idevice_patch.regenerate(
                checkout=checkout,
                revision=revision,
                patch=patch,
                bootstrap_source=source,
            )

            text = patch.read_text()
            self.assertIn("+fn patched() {}", text)
            self.assertIn("+fn added() {}", text)
            patch_sha = hashlib.sha256(patch.read_bytes()).hexdigest()
            tree_sha = bootstrap_idevice.tree_digest(checkout)
            self.assertEqual(
                source.read_text(),
                f'IDEVICE_PATCH_SHA256 = (\n    "{patch_sha}"\n)\n'
                f'IDEVICE_TREE_SHA256 = "{tree_sha}"\n',
            )

            # The checkout's own index is untouched: nothing is staged and the
            # new file is still untracked.
            self.assertEqual(self.git(checkout, "diff", "--cached", "--name-only"), "")
            self.assertIn("?? added.rs", self.git(checkout, "status", "--porcelain"))

            # The patch applies to a clean upstream checkout and reproduces the
            # same tree the digest was taken from.
            clean = root / "clean"
            self.git(root, "clone", "-q", str(checkout), str(clean))
            self.git(clean, "checkout", "-q", revision)
            self.git(clean, "apply", str(patch))
            self.assertEqual(bootstrap_idevice.tree_digest(clean), tree_sha)

    def test_ignored_files_stop_regeneration(self) -> None:
        # The patch cannot carry ignored files, but the tree digest would
        # include them, so a fresh bootstrap could never match it.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "idevice"
            checkout.mkdir()
            self.git(checkout, "init", "-q", "-b", "main")
            self.git(checkout, "config", "user.email", "ci@example.com")
            self.git(checkout, "config", "user.name", "CI Test")
            self.git(checkout, "config", "commit.gpgsign", "false")
            (checkout / ".gitignore").write_text("*.pcap\n/target\n")
            (checkout / "lib.rs").write_text("fn upstream() {}\n")
            self.git(checkout, "add", ".")
            self.git(checkout, "commit", "-q", "-m", "upstream")
            revision = self.git(checkout, "rev-parse", "HEAD").strip()
            (checkout / "lib.rs").write_text("fn patched() {}\n")
            (checkout / "target").mkdir()
            (checkout / "target" / "build.o").write_text("cargo output\n")
            source = root / "bootstrap_idevice.py"
            original = 'IDEVICE_PATCH_SHA256 = (\n    "old"\n)\nIDEVICE_TREE_SHA256 = "old"\n'
            source.write_text(original)
            arguments = dict(
                checkout=checkout,
                revision=revision,
                patch=root / "idevice.patch",
                bootstrap_source=source,
            )

            (checkout / "capture.pcap").write_text("packets\n")
            with self.assertRaisesRegex(bootstrap_idevice.BootstrapError, "capture.pcap"):
                regenerate_idevice_patch.regenerate(**arguments)
            self.assertEqual(source.read_text(), original)

            # Cargo's target directory is outside the digest, so it is fine.
            (checkout / "capture.pcap").unlink()
            regenerate_idevice_patch.regenerate(**arguments)

    def test_the_committed_patch_matches_the_bootstrap_contract(self) -> None:
        specification = bootstrap_idevice.default_specification()
        self.assertEqual(
            hashlib.sha256(specification.patch.read_bytes()).hexdigest(),
            specification.patch_sha256,
        )

    @staticmethod
    def git(repository: Path, *arguments: str) -> str:
        return subprocess.run(
            ("git", *arguments),
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        ).stdout


if __name__ == "__main__":
    unittest.main()
