#!/usr/bin/env python3
"""Land this branch on main: merge it --no-ff onto fetched main, validate that exact merge (Tiers 0 to 2 on the mini), push it only if it passed."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_lock import LAND_LOCK, wait_for_lock  # noqa: E402  (the one host lock owner)

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
SKIP = "ios,mac,python-here"
ARTIFACTS = "mini: artifacts: "


class Refused(Exception):
    def __init__(self, message: str, code: int):
        super().__init__(message)
        self.code = code


def say(text: str) -> None:
    print(f"land: {text}", flush=True)


def git(*args: str, cwd: Path = ROOT) -> str:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if done.returncode:
        raise Refused(f"git {' '.join(args)}: {done.stderr.strip()}", 75)
    return done.stdout.strip()


def fetch_main() -> str:
    git("fetch", "--quiet", "--no-tags", "--refmap=", "origin", "refs/heads/main")
    return git("rev-parse", "FETCH_HEAD")


def merge(tree: Path, main: str, head: str, message: str) -> str:
    git("checkout", "--quiet", "--detach", main, cwd=tree)
    merged = subprocess.run(["git", "-C", str(tree), "merge", "--quiet", "--no-ff", "-m", message, head], capture_output=True, text=True)
    if merged.returncode:
        subprocess.run(["git", "-C", str(tree), "merge", "--abort"], capture_output=True)
        raise Refused(f"{head[:12]} does not merge cleanly onto main {main[:12]}; merge main into the branch, commit and land again", 2)
    return git("rev-parse", "HEAD", cwd=tree)


def validate(tree: Path, sha: str, main: str) -> tuple[str, dict, Path]:
    """('passed', 'failed' or 'no result', the report, where its evidence is kept) for Tiers 0 to 2 at exactly `sha`."""
    command = [sys.executable, str(tree / "tools/verify/mini.py"), "verify", "--full", "--base", main, "--skip", SKIP,
               "--gateway-host", "local", "--ios-host", "local"]
    artifacts = None
    with subprocess.Popen(command, cwd=tree, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as child:
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if line.startswith(ARTIFACTS):
                artifacts = Path(line[len(ARTIFACTS):].strip())
    kept = ROOT / "test-results/land" / sha
    report = {}
    if artifacts and artifacts.is_dir():
        shutil.copytree(artifacts, kept, dirs_exist_ok=True)
        if (kept / "verify.json").is_file():
            report = json.loads((kept / "verify.json").read_text())
    if report.get("commit") != sha:
        return "no result", report, kept
    if report.get("verdict") == "passed" and child.returncode == 0:
        return "passed", report, kept
    return ("failed" if report.get("verdict") == "failed" else "no result"), report, kept


def land(head: str, message: str) -> int:
    scratch = Path(tempfile.mkdtemp(prefix="tron-land-"))
    tree = scratch / "tree"
    main = fetch_main()
    git("worktree", "add", "--quiet", "--detach", str(tree), main)
    try:
        while True:
            if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", head, main]).returncode == 0:
                say(f"{head[:12]} is already on main {main[:12]}")
                return 0
            sha = merge(tree, main, head, message)
            say(f"validating {sha[:12]}: {head[:12]} --no-ff onto main {main[:12]}, Tiers 0 to 2 on the mini")
            verdict, report, kept = validate(tree, sha, main)
            if verdict != "passed":
                why = report.get("message") if report.get("commit") == sha else "no verify report for this commit"
                raise Refused(f"{sha[:12]} {verdict}: {why or 'its report gives no reason'}; "
                              f"evidence {kept}; main stays {main[:12]}", 1 if verdict == "failed" else 75)
            pushed = subprocess.run(["git", "-C", str(ROOT), "push", "--quiet", "origin", f"{sha}:refs/heads/main"],
                                    capture_output=True, text=True)
            now = fetch_main()
            if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", sha, now]).returncode == 0:
                say(f"landed {sha[:12]} on main; evidence {kept}")
                return 0
            if now == main:
                raise Refused(f"push of {sha[:12]} failed and main is unchanged: {pushed.stderr.strip()}", 75)
            say(f"main moved to {now[:12]} during validation; merging and validating again")
            main = now
    finally:
        subprocess.run(["git", "-C", str(ROOT), "worktree", "remove", "--force", str(tree)], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron land", description=__doc__)
    parser.add_argument("-m", "--message", help="merge commit message (default: Merge <branch>)")
    args = parser.parse_args(argv)
    try:
        if git("status", "--porcelain", "--untracked-files=normal"):
            raise Refused("the worktree has uncommitted or untracked changes; land lands a commit, commit first", 2)
        branch, head = git("branch", "--show-current"), git("rev-parse", "HEAD")
        if branch in ("", "main"):
            raise Refused("land a task branch, not main or a detached HEAD", 2)
        record = {"pid": os.getpid(), "worktree": str(ROOT), "branch": branch, "head": head}
        with wait_for_lock(LAND_LOCK, record, say):
            return land(head, args.message or f"Merge {branch}")
    except Refused as refused:
        print(f"land: refused: {refused}", file=sys.stderr, flush=True)
        return refused.code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main(sys.argv[1:]))
