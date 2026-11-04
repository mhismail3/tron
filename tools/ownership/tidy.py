#!/usr/bin/env python3
"""Workspace hygiene: report residue, scratch, worktrees and branches; prune only what is safe.

  scripts/tron tidy            # read-only report, exit 1 when drift needs a decision
  scripts/tron tidy --json     # same, machine-readable (weekly Home sweep)
  scripts/tron tidy --prune    # delete expired scratch/evidence/bytecode, merged branches, merged clean worktrees

Pruning never touches tracked files, unmerged commits, dirty or live worktrees, unknown ignored
paths or anything outside this repository's checkouts. Every branch it deletes is printed with
its restore command.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DAY = 86400
SCRATCH, SCRATCH_DAYS = ".scratch", 7
EVIDENCE, EVIDENCE_DAYS = "test-results", 14
# Ignored paths with a named writer, as exact repo-relative paths. Anything else ignored is
# residue: delete it, or add its writer here and to .gitignore in the same change.
REGENERABLE = {  # deleting loses nothing; the writer recreates it
    ".scratch", "test-results", ".ci-tools", "packages/gateway/node_modules", "packages/gateway/dist",
    "packages/push-relay/node_modules", "packages/push-relay/dist", "packages/push-relay/dist-sandbox",
    "packages/push-relay/.wrangler", "packages/ios-app/TronMobile.xcodeproj", "packages/mac-app/TronMac.xcodeproj",
    "packages/ios-app/MacTerminalSSH/.build", "packages/mac-app/.build", "packages/mac-app/build",
    "packages/mac-app/native-computer-control/.build", "packages/mac-app/native-computer-control/build",
    "packages/mac-app/Sources/Resources/Gateway",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/MacOS",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Resources",
}
LOCAL = {".claude", "packages/mac-app/.env.local"}  # per-user state: never pruned, blocks worktree removal
PROTECTED_BRANCHES = {"main"}


def git(*args: str, cwd: Path = ROOT, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(cwd), "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=False)
    if check and done.returncode:
        raise SystemExit(f"tidy: git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def age_days(path: Path) -> float:
    """Days since anything under path last changed (a rewritten file keeps its folder young)."""
    newest = 0.0
    try:
        newest = path.lstat().st_mtime
        if path.is_dir() and not path.is_symlink():
            for base, _dirs, files in os.walk(path):
                for name in files:
                    try:
                        newest = max(newest, os.lstat(os.path.join(base, name)).st_mtime)
                    except OSError:
                        pass
    except OSError:
        return 0.0
    return (time.time() - newest) / DAY


def activity_days(worktree: Path) -> float:
    """Days since the worktree's HEAD or reflog last changed (its .git file only records creation)."""
    gitdir = Path(git("rev-parse", "--absolute-git-dir", cwd=worktree, check=False).strip() or worktree / ".git")
    # Not the index: `git status` refreshes it. Uncommitted edits already make a worktree dirty.
    times = [(gitdir / name).stat().st_mtime for name in ("HEAD", "logs/HEAD") if (gitdir / name).exists()]
    return round((time.time() - max(times)) / DAY, 1) if times else 0.0


def known(rel: str) -> str | None:
    if rel in LOCAL or any(rel.startswith(k + "/") for k in LOCAL):
        return "local"
    if rel in REGENERABLE or rel.endswith("__pycache__") or (rel.startswith("packages/") and rel.endswith("/test-results")):
        return "regenerable"
    return None


def worktrees() -> list[dict]:
    rows, current = [], {}
    for line in git("worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if current:
                rows.append(current)
            current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value or True
    return rows


def live_cwds() -> set[str] | None:
    """Directories this user's processes run in, or None when lsof is unavailable (then nothing is pruned)."""
    try:
        done = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True, check=False)
    except OSError:
        return None
    return {line[1:] for line in done.stdout.splitlines() if line.startswith("n")}


TEST_NAME = ("test-", "test_")


def dead_tooling() -> list[str]:
    """Standalone tooling that no other tracked code, config or test names (docs and manifests do not count)."""
    import re
    tracked = git("ls-files").splitlines()
    tooling = [p for p in tracked if (p.startswith("scripts/") or "/scripts/" in p)
               and not p.endswith((".md", ".json", ".txt")) and not p.rsplit("/", 1)[-1].startswith(TEST_NAME)
               and ".test." not in p]
    def keys(p: str) -> set:
        name = p.rsplit("/", 1)[-1]
        return {name, name[:-3]} if name.endswith(".py") else {name}  # Python modules are imported by stem
    names = set().union(*(keys(p) for p in tooling))
    pattern = re.compile("|".join(sorted((re.escape(n) for n in names), key=len, reverse=True)))
    seen: dict[str, set] = {}
    for path in tracked:
        if path.endswith((".md", ".tsv", ".module.json", ".png", ".tgz", ".jpg", ".pdf", ".caf", ".ttf", ".icns")):
            continue
        try:
            text = (ROOT / path).read_text(errors="ignore")
        except OSError:
            continue
        for name in set(pattern.findall(text)):
            seen.setdefault(name, set()).add(path)
    return [p for p in tooling if not (set().union(*(seen.get(k, set()) for k in keys(p))) - {p})]


def report(prune: bool) -> dict:
    primary = Path(worktrees()[0]["worktree"])
    out: dict[str, list] = {k: [] for k in ("dead_tooling", "untracked", "residue", "expired", "bytecode", "worktrees",
                                            "orphan_worktree_dirs", "branches", "hook", "pruned")}
    main = git("rev-parse", "--verify", "--quiet", "origin/main", check=False).strip()
    cwds = live_cwds()

    for tree in [Path(w["worktree"]) for w in worktrees() if not w.get("prunable")]:
        status = git("status", "--porcelain", "--ignored", "--untracked-files=normal", cwd=tree, check=False)
        for line in status.splitlines():
            code, rel = line[:2], line[3:].strip('"').rstrip("/")
            where = str(tree / rel)
            if code == "??":
                out["untracked"].append(where)
            elif code == "!!":
                if rel.endswith("__pycache__"):
                    out["bytecode"].append(where)
                elif known(rel) is None:
                    out["residue"].append(where)
        tracked_tops = {p.split("/", 1)[0] for p in git("ls-files", cwd=tree, check=False).splitlines()}
        for entry in tree.iterdir():  # git status hides empty ignored directories such as tmp/
            if entry.is_dir() and entry.name not in tracked_tops | {".git"} and not any(entry.iterdir()):
                out["residue"].append(str(entry))
        for folder, days in ((SCRATCH, SCRATCH_DAYS), (EVIDENCE, EVIDENCE_DAYS)):
            for base in [tree / folder] + list(tree.glob(f"packages/*/{folder}")):
                if base.is_dir():
                    out["expired"] += [str(p) for p in base.iterdir() if age_days(p) > days]

    for w in worktrees()[1:]:
        path, head, branch = w["worktree"], w.get("HEAD", ""), str(w.get("branch", "")).removeprefix("refs/heads/")
        merged = bool(main) and subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", head, main]).returncode == 0
        status = git("status", "--porcelain", "--ignored", "--untracked-files=normal", cwd=Path(path), check=False)
        # Anything but regenerable output counts as local data: `git worktree remove` would delete
        # ignored files (e.g. .env.local) silently, so such a worktree is never pruned.
        dirty = any(not line.startswith("!! ") or known(line[3:].strip('"').rstrip("/")) != "regenerable"
                    for line in status.splitlines())
        live = cwds is None or any(c == path or c.startswith(path + "/") for c in cwds)
        out["worktrees"].append({"path": path, "branch": branch, "merged": merged, "dirty": dirty, "live": live,
                                 "idleDays": activity_days(Path(path))})
    registered = {w["worktree"] for w in worktrees()}
    sibling = primary.parent / f"{primary.name}-worktrees"
    if sibling.is_dir():
        for entry in sibling.iterdir():
            if entry.is_dir() and str(entry) not in registered:
                out["orphan_worktree_dirs"].append(str(entry))

    checked_out = {str(w.get("branch", "")).removeprefix("refs/heads/") for w in worktrees()}
    for line in git("for-each-ref", "--format=%(refname:short) %(objectname) %(committerdate:unix)", "refs/heads").splitlines():
        name, sha, when = line.split(" ")
        merged = bool(main) and subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", sha, main]).returncode == 0
        idle = round((time.time() - int(when)) / DAY)
        if name in PROTECTED_BRANCHES or name in checked_out:
            continue
        if merged or idle > 14:
            out["branches"].append({"branch": name, "sha": sha, "merged": merged, "idleDays": idle})

    out["dead_tooling"] = dead_tooling()

    hook = Path(git("rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit").strip())
    if not hook.exists() or "scripts/tron hook" not in hook.read_text(errors="replace"):
        out["hook"].append(f"{hook} is not the managed hook; run scripts/install-hooks.sh")

    if prune:
        for path in out["expired"] + out["bytecode"]:
            shutil.rmtree(path, ignore_errors=True) if Path(path).is_dir() else Path(path).unlink(missing_ok=True)
            out["pruned"].append(path)
        for w in out["worktrees"]:
            if w["merged"] and not w["dirty"] and not w["live"] and w["idleDays"] >= 3:
                # --force only because regenerable ignored output (node_modules, build) is all that remains.
                if subprocess.run(["git", "-C", str(ROOT), "worktree", "remove", "--force", w["path"]]).returncode == 0:
                    out["pruned"].append(f"worktree {w['path']} (branch {w['branch']} is on main)")
                    checked_out.discard(w["branch"])
        for b in out["branches"]:
            if b["merged"] and b["branch"] not in checked_out:
                if subprocess.run(["git", "-C", str(ROOT), "branch", "-d", b["branch"]], capture_output=True).returncode == 0:
                    out["pruned"].append(f"branch {b['branch']} (restore: git branch {b['branch']} {b['sha']})")
    return out


def main(argv: list[str]) -> int:
    started = time.monotonic()
    result = report("--prune" in argv)
    drift = sum(len(result[k]) for k in ("dead_tooling", "untracked", "residue", "orphan_worktree_dirs", "hook")) \
        + sum(1 for b in result["branches"] if not b["merged"]) \
        + sum(1 for w in result["worktrees"] if not w["merged"] and w["idleDays"] > 7 and not w["live"])
    if "--json" in argv:
        print(json.dumps({**result, "drift": drift, "seconds": round(time.monotonic() - started, 2)}, indent=1))
        return 1 if drift else 0
    fixes = {
        "dead_tooling": "no code, config or test names it: wire it into scripts/tron or delete it",
        "untracked": "commit it with an owner, move it to .scratch/, or delete it",
        "residue": "ignored path with no named writer: delete it, or add its writer to tidy REGENERABLE/LOCAL",
        "expired": f"older than {SCRATCH_DAYS}d scratch / {EVIDENCE_DAYS}d evidence: scripts/tron tidy --prune",
        "bytecode": "scripts/tron tidy --prune (scripts/tron sets PYTHONDONTWRITEBYTECODE)",
        "orphan_worktree_dirs": "not a registered worktree: inspect, then remove it by hand",
        "hook": "",
    }
    for key, fix in fixes.items():
        for item in result[key]:
            print(f"tidy: {key}: {item}" + (f" — {fix}" if fix else ""))
    for w in result["worktrees"]:
        state = "merged" if w["merged"] else "unmerged"
        print(f"tidy: worktree {w['path']} [{w['branch']}] {state}{' dirty' if w['dirty'] else ''}{' live' if w['live'] else ''} idle {w['idleDays']}d")
    merged = [b for b in result["branches"] if b["merged"]]
    stale = [b for b in result["branches"] if not b["merged"]]
    print(f"tidy: branches: {len(merged)} merged (prunable), {len(stale)} unmerged idle >14d (owner decides: land, park or delete)")
    for item in result["pruned"]:
        print(f"tidy: pruned {item}")
    print(f"tidy: {drift} drift item(s) in {time.monotonic() - started:.1f}s")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
