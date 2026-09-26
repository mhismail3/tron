#!/usr/bin/env python3
"""Own the source identity of the iOS test products under the shared build root.

`scripts/tron-ios-test` builds into one products directory per worktree inside
`$HOME/Library/Developer/Tron/ios/test-derived-data` and stamps that directory
with the identity of the source that built it. `run` verifies the stamp before
executing anything, so a shared or replaced products directory can never run a
build from another worktree or another source state.

Commands:
  worktree-key      Print the directory name that owns a worktree's products.
  show              Print this worktree's current source identity as JSON.
  write             Stamp a products directory with the identity read on stdin.
  verify            Prove a products directory matches this worktree's source.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

SCHEMA = "tron.ios-test-build-identity.v1"
IDENTITY_NAME = "build-identity.json"
CHUNK = 1 << 20
IDENTITY_FIELDS = ("worktree", "worktree_key", "revision", "dirty", "source_fingerprint")


class IdentityError(Exception):
    """The source identity could not be read or proven."""


def git(worktree: Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(worktree), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        lines = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        detail = f": {lines[-1]}" if lines else ""
        raise IdentityError(f"git {' '.join(arguments)} failed in {worktree}{detail}")
    return completed.stdout


def repository_root(worktree: Path) -> Path:
    root = Path(os.path.realpath(worktree))
    top = Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel").strip()))
    if os.path.realpath(top) != str(root):
        raise IdentityError(f"{root} is not the top level of a worktree, which is {top}")
    return root


def worktree_key(worktree: Path) -> str:
    """Directory name for one worktree's products under the shared build root."""
    name = re.sub(r"[^A-Za-z0-9._-]", "-", os.path.realpath(worktree).rsplit("/", 1)[-1])[:48]
    digest = hashlib.sha256(os.path.realpath(worktree).encode()).hexdigest()[:12]
    return f"{name or 'worktree'}-{digest}"


def source_state(worktree: Path) -> tuple[bool, str]:
    """Return (dirty, fingerprint) for the worktree's content beyond HEAD.

    Tracked modifications and deletions come from the diff against HEAD; every
    untracked, non-ignored file contributes its path and content, because a new
    test-only source file changes what a build would produce.
    """
    digest = hashlib.sha256()
    diff = git(worktree, "diff", "HEAD", "--binary", "--no-color", "--no-ext-diff", "--no-textconv")
    digest.update(b"diff\0")
    digest.update(diff)
    digest.update(b"untracked\0")
    untracked = sorted(
        path
        for path in git(worktree, "ls-files", "--others", "--exclude-standard", "-z", "--full-name").split(b"\0")
        if path
    )
    for relative in untracked:
        digest.update(relative)
        digest.update(b"\0")
        try:
            with open(worktree / os.fsdecode(relative), "rb") as handle:
                while chunk := handle.read(CHUNK):
                    digest.update(chunk)
        except OSError as error:
            raise IdentityError(f"cannot read the untracked file {os.fsdecode(relative)}: {error}") from error
    return bool(diff.strip() or untracked), digest.hexdigest()


def identity(worktree: Path) -> dict[str, Any]:
    root = repository_root(worktree)
    dirty, fingerprint = source_state(root)
    return {
        "schema": SCHEMA,
        "worktree": str(root),
        "worktree_key": worktree_key(root),
        "revision": os.fsdecode(git(root, "rev-parse", "HEAD").strip()),
        "dirty": dirty,
        "source_fingerprint": fingerprint,
    }


def identity_path(derived_data: Path) -> Path:
    return derived_data / IDENTITY_NAME


def describe(value: dict[str, Any]) -> str:
    return (
        f"worktree {value.get('worktree')}, revision {str(value.get('revision'))[:9]}, "
        f"{'dirty' if value.get('dirty') else 'clean'}, "
        f"source fingerprint {str(value.get('source_fingerprint'))[:12]}"
    )


def command_worktree_key(arguments: argparse.Namespace) -> int:
    print(worktree_key(arguments.worktree))
    return 0


def command_show(arguments: argparse.Namespace) -> int:
    print(json.dumps(identity(arguments.worktree), indent=2, sort_keys=True))
    return 0


def command_write(arguments: argparse.Namespace) -> int:
    try:
        value = json.loads(sys.stdin.read())
    except json.JSONDecodeError as error:
        raise IdentityError(f"invalid identity document on stdin: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise IdentityError(f"identity document is not {SCHEMA}")
    if value.get("worktree") != os.path.realpath(arguments.worktree):
        raise IdentityError(f"identity document names {value.get('worktree')}, not this worktree")
    derived_data = arguments.derived_data
    if not derived_data.is_dir():
        raise IdentityError(f"test products directory does not exist: {derived_data}")
    temporary = derived_data / f".{IDENTITY_NAME}.{os.getpid()}"
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, identity_path(derived_data))
    return 0


def command_verify(arguments: argparse.Namespace) -> int:
    path = identity_path(arguments.derived_data)
    try:
        stored = json.loads(path.read_text())
    except FileNotFoundError:
        print(
            f"error: the test products at {arguments.derived_data} carry no build identity, "
            f"so their source is unknown ({path} is missing)",
            file=sys.stderr,
        )
        return 1
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: unreadable build identity {path}: {error}", file=sys.stderr)
        return 1
    if not isinstance(stored, dict) or stored.get("schema") != SCHEMA:
        print(f"error: unrecognized build identity at {path}", file=sys.stderr)
        return 1
    current = identity(arguments.worktree)
    if all(stored.get(field) == current[field] for field in IDENTITY_FIELDS):
        return 0
    print(
        "error: refusing to run: the test products were not built from this worktree's source state",
        file=sys.stderr,
    )
    print(f"  products:   {arguments.derived_data}", file=sys.stderr)
    print(f"  built from: {describe(stored)}", file=sys.stderr)
    print(f"  current:    {describe(current)}", file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, handler, needs_derived_data in (
        ("worktree-key", command_worktree_key, False),
        ("show", command_show, False),
        ("write", command_write, True),
        ("verify", command_verify, True),
    ):
        subparser = commands.add_parser(name)
        subparser.add_argument("--worktree", required=True, type=Path)
        if needs_derived_data:
            subparser.add_argument("--derived-data", required=True, type=Path)
        subparser.set_defaults(handler=handler)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        return arguments.handler(arguments)
    except IdentityError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
