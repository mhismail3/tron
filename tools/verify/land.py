#!/usr/bin/env python3
"""Land this branch on main: merge it --no-ff onto fetched main, run the merge's affected checks (here, or on the mini when they select iOS work), push it only if they passed."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_lock import GATE, LAND_LOCK, wait_for_lock  # noqa: E402  (the one host lock owner)

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
SKIP = "mac,python-here"
PACKAGES = {"packages/gateway": ("package.json", "package-lock.json", ".npmrc", "third_party"), "packages/push-relay": ("package.json", "package-lock.json", ".npmrc")}


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
    subprocess.run(["chmod", "-R", "u+w", str(tree)], capture_output=True)
    git("checkout", "--quiet", "--detach", "--force", main, cwd=tree)
    git("clean", "-ffdxq", "-e", "node_modules", cwd=tree)
    merged = subprocess.run(["git", "-C", str(tree), "merge", "--quiet", "--no-ff", "-m", message, head], capture_output=True, text=True)
    if merged.returncode:
        subprocess.run(["git", "-C", str(tree), "merge", "--abort"], capture_output=True)
        raise Refused(f"{head[:12]} does not merge cleanly onto main {main[:12]}; merge main into the branch, commit and land again", 2)
    return git("rev-parse", "HEAD", cwd=tree)


def install(tree: Path) -> None:
    """The land tree's dependencies, reinstalled only when a package's inputs or the pinned Node changed."""
    node = subprocess.run([str(tree / "scripts/tron-node")], capture_output=True, text=True)
    if node.returncode:
        raise Refused(f"no pinned Node for the land tree: {node.stderr.strip()}", 75)
    for package, names in PACKAGES.items():
        if not (tree / package / "package-lock.json").is_file():
            continue
        inputs = [git("rev-parse", f"HEAD:{package}/{name}", cwd=tree) for name in names if (tree / package / name).exists()]
        digest = hashlib.sha256(json.dumps([inputs, hashlib.sha256(Path(node.stdout.strip()).read_bytes()).hexdigest()]).encode()).hexdigest()
        stamp = tree / package / "node_modules/.tron-land-install"
        if stamp.is_file() and stamp.read_text() == digest:
            continue
        say(f"{package} dependencies changed; npm ci in the land tree")
        if subprocess.run([str(tree / "scripts/tron-node"), "exec", "npm", "--prefix", package, "ci", "--include=dev"], cwd=tree).returncode:
            raise Refused(f"npm ci in {package} failed in the land tree", 75)
        stamp.parent.mkdir(exist_ok=True)
        stamp.write_text(digest)


def validate(tree: Path, sha: str, main: str) -> tuple[str, dict, Path]:
    """('passed', 'failed' or 'no result', the report, where its evidence is kept) for the affected checks at exactly `sha`:
    here, or, when they select iOS work, the whole verification on the mini under its lease (`--ios-host mini`)."""
    install(tree)
    with subprocess.Popen([sys.executable, str(tree / "tools/verify/verify.py"), "--changed", "--base", main, "--skip", SKIP, "--ios-host", "mini", "--ios-jobs", "3"],
                          cwd=tree, stdin=subprocess.DEVNULL, env={**os.environ, GATE: "1"}) as child:
        try:
            code = child.wait()
        except BaseException:
            child.terminate()
            child.wait()
            raise
    kept = ROOT / "test-results/land" / sha
    found, logs = tree / "test-results/verify" / f"{sha}.json", tree / "test-results/verify" / sha
    handed = next((tree / "test-results/mini").glob(f"{sha[:12]}-*/verify.json"), None)
    if handed:
        found, logs = handed, handed.parent / "verify"
    report = {}
    if found.is_file():
        kept.mkdir(parents=True, exist_ok=True)
        shutil.copy2(found, kept / "verify.json")
        if logs.is_dir():
            shutil.copytree(logs, kept / "verify", dirs_exist_ok=True)
        report = json.loads((kept / "verify.json").read_text())
    if report.get("commit") != sha:
        return "no result", report, kept
    if report.get("verdict") == "passed" and code == 0:
        return "passed", report, kept
    return ("failed" if report.get("verdict") == "failed" else "no result"), report, kept


def start_main_suite(sha: str) -> None:
    """Start the landed commit's main suite on this host, detached, from the clone's primary checkout; runs queue on its
    lock, and each judges the newest main not yet judged."""
    source = subprocess.run(["git", "-C", str(ROOT), "show", f"{sha}:tools/verify/main_suite.py"], capture_output=True, text=True)
    if source.returncode:
        return
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
    tool, logs = common / "tron-land-tool" / "main_suite.py", common / "tron-main-suite"
    tool.parent.mkdir(exist_ok=True)
    logs.mkdir(exist_ok=True)
    tool.write_text(source.stdout)
    with open(logs / "main-suite.log", "a") as log:
        subprocess.Popen([sys.executable, str(tool)], cwd=common.parent, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    say(f"main suite started; log {logs / 'main-suite.log'}")


def land(head: str, message: str) -> int:
    tree = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "tron-land-tree"
    main = fetch_main()
    if not (tree / ".git").exists():
        git("worktree", "add", "--quiet", "--detach", str(tree), main)
    try:
        while True:
            if subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", head, main]).returncode == 0:
                say(f"{head[:12]} is already on main {main[:12]}")
                return 0
            sha = merge(tree, main, head, message)
            say(f"validating {sha[:12]}: {head[:12]} --no-ff onto main {main[:12]}, its affected checks")
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
                start_main_suite(sha)
                return 0
            if now == main:
                raise Refused(f"push of {sha[:12]} failed and main is unchanged: {pushed.stderr.strip()}", 75)
            say(f"main moved to {now[:12]} during validation; merging and validating again")
            main = now
    finally:
        subprocess.run(["git", "-C", str(tree), "checkout", "--quiet", "--detach", "--force", main], capture_output=True)


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
