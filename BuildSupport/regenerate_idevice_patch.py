#!/usr/bin/env python3
"""Rewrite Device Hub's idevice patch from edits made in Vendor/idevice.

Edit the materialized checkout, run this, then review and commit the patch and
the updated digests in bootstrap_idevice.py. The patch is the checkout's full
diff (including new files) against the pinned upstream revision, so it always
reproduces exactly the tree whose digest is recorded.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import bootstrap_idevice


def _git(checkout: Path, *arguments: str, index: Path | None = None) -> bytes:
    environment = None if index is None else {**os.environ, "GIT_INDEX_FILE": str(index)}
    return subprocess.run(
        ("git", *arguments),
        cwd=checkout,
        check=True,
        capture_output=True,
        env=environment,
    ).stdout


def regenerate(
    *,
    checkout: Path,
    revision: str,
    patch: Path,
    bootstrap_source: Path,
) -> None:
    """Write the patch and record its digest and the tree digest."""

    # The patch cannot carry ignored files, but the tree digest includes
    # everything except Git metadata and Cargo's top-level target directory.
    ignored = [
        path
        for path in _git(
            checkout, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory"
        ).decode().splitlines()
        if path.split("/", 1)[0] != "target"
    ]
    if ignored:
        raise bootstrap_idevice.BootstrapError(
            "remove ignored files from the idevice checkout first: " + ", ".join(ignored)
        )

    # Intent-to-add makes new files part of the diff. It runs on a copy of the
    # index so the checkout's own staging area is left as it was.
    with tempfile.TemporaryDirectory() as scratch:
        index = Path(scratch) / "index"
        git_index = Path(_git(checkout, "rev-parse", "--git-path", "index").decode().strip())
        git_index = git_index if git_index.is_absolute() else checkout / git_index
        if git_index.exists():
            shutil.copyfile(git_index, index)
        _git(checkout, "add", "--intent-to-add", "--all", index=index)
        patch.write_bytes(
            _git(checkout, "diff", "--full-index", "--binary", revision, index=index)
        )

    patch_sha256 = hashlib.sha256(patch.read_bytes()).hexdigest()
    tree_sha256 = bootstrap_idevice.tree_digest(checkout)
    source = bootstrap_source.read_text()
    source, patch_count = re.subn(
        r'(IDEVICE_PATCH_SHA256 = \(\n    ")[0-9a-z]+(")',
        rf"\g<1>{patch_sha256}\g<2>",
        source,
    )
    source, tree_count = re.subn(
        r'(IDEVICE_TREE_SHA256 = ")[0-9a-z]+(")',
        rf"\g<1>{tree_sha256}\g<2>",
        source,
    )
    if patch_count != 1 or tree_count != 1:
        raise bootstrap_idevice.BootstrapError(
            "could not find the idevice digests in bootstrap_idevice.py"
        )
    bootstrap_source.write_text(source)


def main() -> int:
    specification = bootstrap_idevice.default_specification()
    regenerate(
        checkout=specification.destination,
        revision=specification.revision,
        patch=specification.patch,
        bootstrap_source=Path(bootstrap_idevice.__file__).resolve(),
    )
    print(f"Rewrote {specification.patch.name} and the idevice digests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
