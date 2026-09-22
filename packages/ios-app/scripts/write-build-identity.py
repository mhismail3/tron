#!/usr/bin/env python3
"""Stamp only source revision and dirty state into the built app before signing."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

revision = git("rev-parse", "HEAD")
assert len(revision) == 40 and all(c in "0123456789abcdef" for c in revision)
identity = {"revision": revision, "dirty": bool(git("status", "--porcelain", "--untracked-files=normal"))}
destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "TronBuildIdentity.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(identity, separators=(",", ":")) + "\n")
