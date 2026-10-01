"""Seed isolated build dependencies and compiler caches for a new worktree."""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Callable


class WarmError(RuntimeError):
    """A worktree could not be made ready without violating cache isolation."""


_PACKAGE_PATHS = (Path("packages/gateway"), Path("packages/push-relay"))
_IOS_CACHE_NAMES = ("ModuleCache.noindex", "SDKStatCaches.noindex")


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
    subprocess.run(["npm", "ci"], cwd=package, check=True)


def _installed_from_lock(package: Path, lockfile: Path) -> bool:
    """Reject empty or incomplete node_modules trees before considering a clone."""
    try:
        expected = json.loads(lockfile.read_text())
        installed = json.loads((package / "node_modules/.package-lock.json").read_text())
        expected_packages = expected["packages"]
        installed_packages = installed["packages"]
        return bool(installed_packages) and all(
            path in expected_packages and expected_packages[path] == metadata
            for path, metadata in installed_packages.items()
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


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


def seed_ios_build_cache(primary_products: Path, worktree_products: Path) -> None:
    """Copy only Xcode's compiler/SDK caches; never share worktree build products."""
    marker = worktree_products / ".tron-ios-test-owned"
    if worktree_products.is_symlink():
        return
    if worktree_products.exists():
        try:
            if marker.is_symlink() or not marker.is_file() or marker.read_text() != "tron.ios-test-owned.v1\n":
                return
        except OSError:
            return
    elif any((primary_products / name).is_dir() for name in _IOS_CACHE_NAMES):
        worktree_products.mkdir(parents=True)
        marker.write_text("tron.ios-test-owned.v1\n")
    for name in _IOS_CACHE_NAMES:
        source = primary_products / name
        destination = worktree_products / name
        if destination.exists() or destination.is_symlink():
            continue
        if source.is_dir() and not source.is_symlink():
            _seed_directory(source, destination)


def seed_worktree(primary: Path, worktree: Path) -> None:
    seed_node_modules(primary, worktree)
    home = Path.home()
    identity_tool = worktree / "scripts/ios-test-build-identity.py"
    if not identity_tool.is_file() or not (primary / "scripts/ios-test-build-identity.py").is_file():
        return
    try:
        key = subprocess.run(["python3", str(identity_tool), "worktree-key", "--worktree", str(primary)],
                             check=True, capture_output=True, text=True).stdout.strip()
        target_key = subprocess.run(["python3", str(identity_tool), "worktree-key", "--worktree", str(worktree)],
                                    check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise WarmError(f"cannot identify iOS build cache ownership: {error}") from error
    products_root = home / "Library/Developer/Tron/ios/test-derived-data"
    seed_ios_build_cache(products_root / key, products_root / target_key)
