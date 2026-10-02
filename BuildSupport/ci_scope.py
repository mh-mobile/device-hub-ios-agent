"""Select the smallest safe local CI scope for the current Git checkout."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path
from typing import Iterable

# The default branch, never the branch's own upstream: for a pushed feature
# branch the upstream is HEAD, which would hide every pushed commit.
DEFAULT_BASE_REFERENCES = ("origin/HEAD", "origin/main", "main")


def is_documentation_only(paths: Iterable[str] | None) -> bool:
    """Return whether every changed path is documentation.

    `None` means the change set could not be determined, which is never
    documentation-only.
    """
    if paths is None:
        return False
    changed_paths = tuple(paths)
    return bool(changed_paths) and all(
        path == "LICENSE"
        or path.endswith(".md")
        or path.startswith("Docs/")
        for path in changed_paths
    )


def _git_lines(repository: Path, *arguments: str) -> set[str]:
    result = subprocess.run(
        ("git", *arguments),
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    )
    return {line for line in result.stdout.splitlines() if line}


def _merge_base(repository: Path) -> str | None:
    for reference in DEFAULT_BASE_REFERENCES:
        result = subprocess.run(
            ("git", "merge-base", reference, "HEAD"),
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return None


def changed_paths(repository: Path) -> set[str] | None:
    """Return every path changed since the default branch, including deletions.

    Covers commits not yet on the upstream or default branch plus staged,
    unstaged, and untracked work. Returns `None` when no base can be found.
    """
    base = _merge_base(repository)
    if base is None:
        return None
    # --no-renames lists a renamed file's old path too, so moving source into
    # Docs/ is not mistaken for a documentation change.
    paths = _git_lines(repository, "diff", "--name-only", "--no-renames", base)
    paths |= _git_lines(repository, "ls-files", "--others", "--exclude-standard")
    return paths


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    paths = changed_paths(arguments.repository.resolve())
    print("documentation" if is_documentation_only(paths) else "full")


if __name__ == "__main__":
    main()
