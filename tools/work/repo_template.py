"""Copy-per-test Git fixtures for the work-tooling tests.

Building a bare remote and its clones costs a dozen Git processes for every test.
A test module builds its history once, in setUpModule, and each test copies that
tree and points the copied clones' origin at its own remote. A copy keeps every
object ID, so a SHA recorded while building the template is valid in each copy.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def clone_with_identity(origin: Path, path: Path) -> Path:
    """Clone `origin` into `path` with a test author identity, for building a template."""
    _git(path.parent, "clone", "-q", str(origin), str(path))
    _git(path, "config", "user.name", "Agent")
    _git(path, "config", "user.email", "agent@example.invalid")
    return path


def copy_template(template: Path, destination: Path, clones: list[Path], remote_name: str, remote: Path) -> None:
    """Copy `template` into `destination`, then point each copied clone's `remote_name` at `remote`."""
    shutil.copytree(template, destination, symlinks=True, dirs_exist_ok=True)
    for clone in clones:
        _git(clone, "remote", "set-url", remote_name, str(remote))
