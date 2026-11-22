#!/usr/bin/env python3
"""The main suite: every test file on each new main commit, on the mini under its job lock, off the landing path; a red is bisected over main's first-parent merges and its culprit reverted through land (tools/verify/land.md)."""
from __future__ import annotations

import argparse
import fcntl
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip())
SKIP = "ios,mac,python-here"
ARTIFACTS = "mini: artifacts: "


class NoResult(Exception):
    pass


def git(*args: str, cwd: Path | None = None) -> str:
    done = subprocess.run(["git", "-C", str(cwd or ROOT), *args], capture_output=True, text=True)
    if done.returncode:
        raise NoResult(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout.strip()


def say(text: str) -> None:
    print(f"main-suite: {text}", flush=True)


def home() -> Path:
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")) / "tron-main-suite"


def warm_tree(name: str, sha: str) -> Path:
    """One reused checkout per role, exactly at `sha`."""
    tree = home() / name
    if not (tree / ".git").exists():
        git("worktree", "add", "--quiet", "--detach", str(tree), sha)
    subprocess.run(["chmod", "-R", "u+w", str(tree)], capture_output=True)
    git("checkout", "--quiet", "--detach", "--force", sha, cwd=tree)
    git("clean", "-ffdxq", cwd=tree)
    return tree


def verify(sha: str, args: list[str]) -> dict:
    """The commit's own verify at exactly `sha` on the mini, under its job lock: its report, or a 'no result' verdict."""
    tree = warm_tree("tree", sha)
    artifacts = None
    with subprocess.Popen([sys.executable, str(tree / "tools/verify/mini.py"), "verify", *args, "--skip", SKIP, "--gateway-host", "local",
                           "--ios-host", "local"], cwd=tree, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True) as child:
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if line.startswith(ARTIFACTS):
                artifacts = Path(line[len(ARTIFACTS):].strip())
    report = artifacts / "verify.json" if artifacts else None
    data = json.loads(report.read_text()) if report and report.is_file() else {}
    return data if data.get("commit") == sha and data.get("verdict") in ("passed", "failed") else {"verdict": "no result"}


def red_files(report: dict) -> list[str]:
    """The test files a red report names: each failed case's file when the group's failure list is complete, else every
    file of the failed group."""
    files: set[str] = set()
    for step in report.get("steps", []):
        if step.get("status") != "failed" or not step["name"].startswith("tests: "):
            continue
        named = {case.split("::", 1)[0] for case in step.get("failedTests", []) if "::" in case}
        whole = report.get("groups", {}).get(step["name"].removeprefix("tests: "), [])
        files |= named if named and step.get("failedTestsComplete", True) else set(whole) or named
    return sorted(files)


def checks(files: list[str], base: str) -> list[str]:
    """The red files alone, or every file when the red named none (a static check)."""
    return ["--files", *files, "--base", base] if files else ["--full", "--base", base]


def probe(sha: str, files: list[str]) -> str:
    """The red files' verdict at `sha` against its own first parent; files that do not exist there yet pass."""
    present = [path for path in files if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{sha}:{path}"],
                                                        capture_output=True).returncode == 0]
    if files and not present:
        return "passed"
    return verify(sha, checks(present, f"{sha}^1"))["verdict"]


def culprit(candidates: list[str], files: list[str]) -> str:
    """The first first-parent commit whose probe is red; the last candidate is known red."""
    low, high = -1, len(candidates) - 1
    while high - low > 1:
        middle = (low + high) // 2
        verdict = probe(candidates[middle], files)
        say(f"probe {candidates[middle][:12]}: {verdict}")
        if verdict == "failed":
            high = middle
        elif verdict == "passed":
            low = middle
        else:
            raise NoResult(f"probe of {candidates[middle][:12]} gave no result")
    return candidates[high]


def revert(main: str, guilty: str, files: list[str]) -> int:
    tree = warm_tree("revert", main)
    branch = f"main-suite/revert-{guilty[:12]}"
    git("checkout", "--quiet", "-B", branch, main, cwd=tree)
    parents = git("rev-list", "--parents", "-n", "1", guilty).split()[1:]
    try:
        git("-c", "core.editor=true", "revert", "--no-edit", *(["-m", "1"] if len(parents) > 1 else []), guilty, cwd=tree)
    except NoResult:
        subprocess.run(["git", "-C", str(tree), "revert", "--abort"], capture_output=True)
        raise NoResult(f"{guilty[:12]} does not revert cleanly onto {main[:12]}; revert it by hand")
    message = f"Revert {guilty[:12]}: the main suite went red on {', '.join(files) or 'its static checks'}"
    git("commit", "--quiet", "--amend", "-m", message, cwd=tree)
    try:
        return subprocess.run([str(tree / "scripts/tron"), "land", "-m", f"Merge {branch}: {message}"], cwd=tree).returncode
    finally:
        git("checkout", "--quiet", "--detach", main, cwd=tree)
        git("branch", "-D", branch, cwd=tree)


def judge(state: dict, main: str, save) -> tuple[int, dict]:
    green = state["green"]
    say(f"main {main[:12]}: every test file, since green {green[:12]}")
    full = verify(main, ["--full", "--base", green])
    if full["verdict"] == "passed":
        say(f"main {main[:12]} green")
        return 0, {**state, "green": main, "judged": main}
    state = {**state, "judged": main}
    save(state)
    if full["verdict"] != "failed":
        say(f"main {main[:12]}: no result; not green, nothing reverted")
        return 75, state
    files = red_files(full)
    again = verify(main, checks(files, green))["verdict"]
    if again == "passed":
        say(f"main {main[:12]} red, but its red files passed on their own at the same commit: nondeterministic; nothing "
            f"reverted, main not green; both outcomes are in the test ledger (scripts/tron flakes): {', '.join(files)}")
        return 1, state
    if again != "failed":
        say(f"main {main[:12]} red; rerunning its red files gave no result")
        return 75, state
    candidates = git("rev-list", "--first-parent", "--reverse", f"{green}..{main}").split()
    reverts = [index for index, sha in enumerate(candidates) if git("log", "-1", "--format=%s", sha).startswith("Merge main-suite/revert-")]
    if reverts:
        boundary = candidates[reverts[-1]]
        if probe(boundary, files) != "passed":
            raise NoResult(f"the red files are red at or before the last main-suite revert {boundary[:12]}; nothing reverted")
        candidates = candidates[reverts[-1] + 1:]
    guilty = culprit(candidates, files)
    if guilty in state.get("reverted", []):
        say(f"main {main[:12]} red again at {guilty[:12]}, already reverted; nothing reverted twice")
        return 1, state
    say(f"culprit {guilty[:12]} ({git('log', '-1', '--format=%s', guilty)}); reverting it through land")
    landed = revert(main, guilty, files)
    if landed:
        say(f"the revert of {guilty[:12]} did not land (exit {landed})")
        return landed, state
    return 1, {**state, "reverted": [*state.get("reverted", []), guilty]}


def run(state_file: Path) -> int:
    """Judge main, then any main that landed meanwhile, until the latest main is judged."""
    code = 0
    while True:
        git("fetch", "--quiet", "--no-tags", "--refmap=", "origin", "refs/heads/main")
        main, state = git("rev-parse", "FETCH_HEAD"), json.loads(state_file.read_text())
        if main == state.get("judged", state["green"]):
            say(f"main {main[:12]} already judged")
            return code
        code, state = judge(state, main, lambda judged: state_file.write_text(json.dumps(judged) + "\n"))
        state_file.write_text(json.dumps(state) + "\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron main-suite", description=__doc__)
    parser.add_argument("--green", metavar="SHA", help="record SHA as the last green main (first run)")
    args = parser.parse_args(argv)
    try:
        home().mkdir(exist_ok=True)
        with open(home() / "lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            global ROOT
            ROOT = warm_tree("tree", git("rev-parse", "HEAD"))
            state_file = home() / "state.json"
            if args.green:
                state_file.write_text(json.dumps({"green": git("rev-parse", "--verify", args.green)}) + "\n")
            if not state_file.is_file():
                print("main-suite: no green main recorded; pass --green <sha> once", file=sys.stderr)
                return 2
            return run(state_file)
    except NoResult as error:
        say(f"no result: {error}")
        return 75


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
