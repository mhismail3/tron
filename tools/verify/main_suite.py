#!/usr/bin/env python3
"""The main suite: every test file on each new main commit, off the landing path; a red is bisected over main's first-parent merges and its culprit reverted through land (tools/verify/land.md)."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
SKIP = "ios,mac,python-here"
PACKAGES = ("packages/gateway", "packages/push-relay")


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True).stdout.strip()


def say(text: str) -> None:
    print(f"main-suite: {text}", flush=True)


def home() -> Path:
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "tron-main-suite"


def warm_tree(name: str, sha: str) -> Path:
    """One reused checkout per role: its node_modules stay, and npm ci runs only when a lockfile changed."""
    tree = home() / name
    if not (tree / ".git").exists():
        git("worktree", "add", "--quiet", "--detach", str(tree), sha)
    git("checkout", "--quiet", "--detach", "--force", sha, cwd=tree)
    git("clean", "-ffdxq", "-e", "node_modules", cwd=tree)
    for package in PACKAGES:
        lock = tree / package / "package-lock.json"
        if not lock.is_file():
            continue
        digest = hashlib.sha256(lock.read_bytes()).hexdigest()
        stamp = tree / package / "node_modules/.tron-main-suite-install"
        if not stamp.is_file() or stamp.read_text() != digest:
            say(f"{package} lockfile changed; npm ci")
            subprocess.run([str(tree / "scripts/tron-node"), "exec", "npm", "--prefix", package, "ci", "--include=dev"], cwd=tree, check=True)
            stamp.parent.mkdir(exist_ok=True)
            stamp.write_text(digest)
    return tree


def verify(sha: str, args: list[str]) -> dict:
    """The commit's own verify at exactly `sha`: its report, or a 'no result' verdict."""
    tree = warm_tree("tree", sha)
    subprocess.run([sys.executable, str(tree / "tools/verify/verify.py"), *args, "--skip", SKIP, "--gateway-host", "local"],
                   cwd=tree, stdin=subprocess.DEVNULL)
    report = tree / "test-results/verify" / f"{sha}.json"
    data = json.loads(report.read_text()) if report.is_file() else {}
    return data if data.get("commit") == sha else {"verdict": "no result"}


def red_files(report: dict) -> list[str]:
    """The test files a red report names: each failed case's file, else every file of a failed group."""
    files: set[str] = set()
    for step in report.get("steps", []):
        if step.get("status") != "failed" or not step["name"].startswith("tests: "):
            continue
        named = {case.split("::", 1)[0] for case in step.get("failedTests", []) if "::" in case}
        files |= named or set(report.get("groups", {}).get(step["name"].removeprefix("tests: "), []))
    return sorted(files)


def culprit(green: str, candidates: list[str], probe: list[str]) -> tuple[str | None, str]:
    """The first first-parent commit after `green` whose probe is red; the last candidate is known red."""
    low, high = -1, len(candidates) - 1
    while high - low > 1:
        middle = (low + high) // 2
        verdict = verify(candidates[middle], probe)["verdict"]
        say(f"probe {candidates[middle][:12]}: {verdict}")
        if verdict == "failed":
            high = middle
        elif verdict == "passed":
            low = middle
        else:
            return None, f"probe of {candidates[middle][:12]} gave {verdict}"
    return candidates[high], "found"


def revert(main: str, guilty: str, files: list[str]) -> int:
    tree = warm_tree("revert", main)
    branch = f"main-suite/revert-{guilty[:12]}"
    git("checkout", "--quiet", "-B", branch, main, cwd=tree)
    parents = git("rev-list", "--parents", "-n", "1", guilty).split()[1:]
    git("-c", "core.editor=true", "revert", "--no-edit", *(["-m", "1"] if len(parents) > 1 else []), guilty, cwd=tree)
    message = f"Revert {guilty[:12]}: the main suite went red on {', '.join(files) or 'its static checks'}"
    git("commit", "--quiet", "--amend", "-m", message, cwd=tree)
    return subprocess.run([str(tree / "scripts/tron"), "land", "-m", f"Merge {branch}: {message}"], cwd=tree).returncode


def once(state_file: Path) -> int:
    state = json.loads(state_file.read_text())
    git("fetch", "--quiet", "--no-tags", "--refmap=", "origin", "refs/heads/main")
    main, green = git("rev-parse", "FETCH_HEAD"), state["green"]
    if main == green:
        say(f"main {main[:12]} is green")
        return 0
    say(f"main {main[:12]}: every test file, since green {green[:12]}")
    full = verify(main, ["--full", "--base", green])
    if full["verdict"] == "passed":
        state_file.write_text(json.dumps({**state, "green": main}) + "\n")
        say(f"main {main[:12]} green")
        return 0
    if full["verdict"] != "failed":
        say(f"main {main[:12]}: {full['verdict']}; not green, nothing reverted")
        return 75
    files = red_files(full)
    probe = ["--files", *files] if files else ["--full", "--base", green]
    again = verify(main, probe)["verdict"]
    if again != "failed":
        say(f"main {main[:12]} red, but its red files gave {again} on their own: nondeterministic, nothing reverted; "
            f"see scripts/tron flakes ({', '.join(files)})")
        return 1
    candidates = git("rev-list", "--first-parent", "--reverse", f"{green}..{main}").split()
    guilty, why = culprit(green, candidates, probe)
    if guilty is None:
        say(f"main {main[:12]} red; no culprit: {why}")
        return 75
    say(f"culprit {guilty[:12]} ({git('log', '-1', '--format=%s', guilty)}); reverting it through land")
    landed = revert(main, guilty, files)
    state_file.write_text(json.dumps({**state, "reverted": [*state.get("reverted", []), guilty]}) + "\n")
    return 1 if landed == 0 else landed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron main-suite", description=__doc__)
    parser.add_argument("--green", metavar="SHA", help="record SHA as the last green main (first run)")
    parser.add_argument("--watch", type=int, metavar="SECONDS", help="check main again every SECONDS")
    args = parser.parse_args(argv)
    home().mkdir(exist_ok=True)
    state_file = home() / "state.json"
    if args.green:
        state_file.write_text(json.dumps({"green": git("rev-parse", "--verify", args.green)}) + "\n")
    if not state_file.is_file():
        print("main-suite: no green main recorded; pass --green <sha> once", file=sys.stderr)
        return 2
    while True:
        code = once(state_file)
        if args.watch is None:
            return code
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
