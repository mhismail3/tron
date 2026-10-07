"""Seed isolated npm dependencies for a new worktree."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Callable


class WarmError(RuntimeError):
    """A worktree could not be made ready without violating cache isolation."""


_PACKAGE_PATHS = (Path("packages/gateway"), Path("packages/push-relay"))


def _clone_tree(source: Path, destination: Path) -> None:
    """Create independent APFS copy-on-write files; refuse shared hard-link state."""
    if not source.is_dir() or source.is_symlink():
        raise OSError(f"clone source is not a regular directory: {source}")
    subprocess.run(["cp", "-cR", str(source), str(destination)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def _seed_directory(source: Path, destination: Path) -> bool:
    """Clone via a sibling temporary path and atomically publish a complete tree."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_root = Path(tempfile.mkdtemp(prefix=".tron-warm-", dir=destination.parent))
    temporary = temporary_root / destination.name
    try:
        _clone_tree(source, temporary)
        temporary.rename(destination)
        return True
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        shutil.rmtree(temporary_root, ignore_errors=True)


def _npm_ci(package: Path) -> None:
    subprocess.run(["npm", "ci"], cwd=package, check=True,
                   env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})


def _installed_from_lock(package: Path, lockfile: Path) -> bool:
    """Reject empty, stale or incomplete node_modules trees before cloning."""
    try:
        expected = json.loads(lockfile.read_text())
        installed = json.loads((package / "node_modules/.package-lock.json").read_text())
        expected_packages = expected["packages"]
        installed_packages = installed["packages"]
        metadata_matches = bool(installed_packages) and all(
            path in expected_packages and expected_packages[path] == metadata
            for path, metadata in installed_packages.items()
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return metadata_matches and _npm_tree_valid(package)


def _npm_tree_valid(package: Path) -> bool:
    """Let npm check required, optional-platform and peer dependency completeness."""
    try:
        result = subprocess.run(["npm", "ls", "--all", "--json"], cwd=package,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return False
    return result.returncode == 0


def seed_node_modules(primary: Path, worktree: Path, *,
                      install: Callable[[Path], None] = _npm_ci) -> None:
    """Seed supported package installs only when the lockfile is byte-identical."""
    for relative in _PACKAGE_PATHS:
        source_package = primary / relative
        target_package = worktree / relative
        source_lock = source_package / "package-lock.json"
        target_lock = target_package / "package-lock.json"
        if not target_package.is_dir() or not target_lock.is_file():
            continue
        destination = target_package / "node_modules"
        if destination.exists() or destination.is_symlink():
            continue
        try:
            matching = (source_lock.is_file() and not source_lock.is_symlink()
                        and source_lock.read_bytes() == target_lock.read_bytes())
        except OSError:
            matching = False
        source_modules = source_package / "node_modules"
        seeded = (matching and source_modules.is_dir() and not source_modules.is_symlink()
                  and _installed_from_lock(source_package, source_lock)
                  and _seed_directory(source_modules, destination))
        if not seeded:
            try:
                install(target_package)
            except (OSError, subprocess.SubprocessError) as error:
                raise WarmError(f"cannot install dependencies in {target_package}: {error}") from error
