#!/usr/bin/env python3
"""Workspace hygiene: report residue, scratch, worktrees and branches; prune only what main already has.

  scripts/tron tidy            # read-only report; exit 1 when something needs a decision
  scripts/tron tidy --json     # the same report, machine-readable
  scripts/tron tidy --prune    # also delete expired scratch/evidence, bytecode, merged branches and worktrees
  scripts/tron tidy --here     # this worktree only: what its agent must clean before it reports (exit 1 if any)
  scripts/tron tidy --here --landing  # only what may not land: untracked files and ignored residue (verify runs it)

Pruning never touches tracked files, unmerged commits, worktrees holding local files or a live
process, unknown ignored paths or directories that are not registered worktrees. Every branch it
deletes is printed with its restore command (tools/ownership/README.md, "Workspace hygiene").
"""

from __future__ import annotations

import filecmp
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DAY = 86400
SCRATCH, SCRATCH_DAYS = ".scratch", 7
EVIDENCE, EVIDENCE_DAYS = "test-results", 14
IDLE_DAYS, BRANCH_IDLE_DAYS = 3, 14
REGENERABLE = {
    SCRATCH, EVIDENCE, ".ci-tools", "packages/gateway/node_modules", "packages/gateway/dist",
    "packages/push-relay/node_modules", "packages/push-relay/dist", "packages/push-relay/dist-sandbox",
    "packages/push-relay/.wrangler", "packages/ios-app/TronMobile.xcodeproj", "packages/mac-app/TronMac.xcodeproj",
    "packages/ios-app/MacTerminalSSH/.build", "packages/mac-app/.build", "packages/mac-app/build",
    "packages/mac-app/native-computer-control/.build", "packages/mac-app/native-computer-control/build",
    "packages/mac-app/Sources/Resources/Gateway",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/MacOS",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Resources",
    "packages/ios-app/build/DerivedData", "packages/ios-app/build/DerivedData-fast-debug", "packages/ios-app/build/share",
    "packages/ios-app/MacTerminalSSH/Package.resolved",
}
PI_SCRATCH = ".pi"
LOCAL = {".claude", "progress.md", "packages/mac-app/.env.local"}
PROTECTED_BRANCHES = {"main"}
TEST_NAME = re.compile(r"(^test[-_])|(\.test\.)")
SKIP_SCAN = (".md", ".tsv", ".module.json", ".png", ".jpg", ".pdf", ".tgz", ".caf", ".ttf", ".otf", ".icns")


def git(*args: str, cwd: Path = ROOT, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(cwd), "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=False)
    if check and done.returncode:
        raise SystemExit(f"tidy: git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def unquote(path: str) -> str:
    return path[1:-1].encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1").decode() \
        if path.startswith('"') else path


def age_days(path: Path) -> float:
    """Days since anything under path last changed: a rewritten file keeps its folder young."""
    try:
        newest = path.lstat().st_mtime
    except OSError:
        return 0.0
    if path.is_dir() and not path.is_symlink():
        for base, _dirs, files in os.walk(path):
            for name in files:
                try:
                    newest = max(newest, os.lstat(os.path.join(base, name)).st_mtime)
                except OSError:
                    pass
    return (time.time() - newest) / DAY


def activity_days(worktree: Path) -> float:
    """Days since the worktree's HEAD or reflog changed. Its .git file records only creation, and
    `git status` rewrites the index; uncommitted edits already make a worktree dirty."""
    gitdir = Path(git("rev-parse", "--absolute-git-dir", cwd=worktree, check=False).strip() or worktree / ".git")
    times = [(gitdir / name).stat().st_mtime for name in ("HEAD", "logs/HEAD") if (gitdir / name).exists()]
    return round((time.time() - max(times)) / DAY, 1) if times else 0.0


def known(rel: str, tree: Path) -> str | None:
    if rel in LOCAL:
        return "local"
    if rel in REGENERABLE or rel.endswith("__pycache__") or (rel.startswith("packages/") and rel.endswith("/" + EVIDENCE)) \
            or (pi_scratch(rel) and (tree / rel).is_file()):
        return "regenerable"
    return None


def pi_scratch(rel: str) -> bool:
    return rel.startswith(PI_SCRATCH + "/") and rel.count("/") == 1


def ignored_entries(tree: Path, rel: str) -> list[str]:
    """Git collapses an ignored directory to one entry; split one that holds a named writer's output."""
    if not any(known_path.startswith(rel + "/") for known_path in REGENERABLE | LOCAL):
        return [rel]
    folder = tree / rel
    if folder.is_symlink() or not folder.is_dir():
        return [rel]
    return [entry for child in sorted(folder.iterdir()) for entry in ignored_entries(tree, f"{rel}/{child.name}")]


def tracked_ignored(tree: Path) -> list[str]:
    """Tracked files the ignore rules also match: `git add` or `git clean -X` would treat them as ignored."""
    return git("ls-files", "-c", "-i", "--exclude-standard", cwd=tree, check=False).splitlines()


def uncopied_evidence(tree: Path, primary: Path) -> list[str]:
    """Unexpired evidence files under the worktree's test-results/ that the primary checkout does not hold."""
    evidence, kept = tree / EVIDENCE, []
    if not evidence.is_dir() or evidence.is_symlink() or age_days(evidence) > EVIDENCE_DAYS:
        return kept
    for base, _dirs, files in os.walk(evidence):
        for name in files:
            path = Path(base) / name
            copy = primary / EVIDENCE / path.relative_to(evidence)
            if path.is_symlink() or not copy.is_file() or not filecmp.cmp(path, copy, shallow=False):
                kept.append(str(path.relative_to(tree)))
    return kept


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
    """Real paths this user's processes run in, or None when lsof is unavailable."""
    try:
        done = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True, check=False)
    except OSError:
        return None
    return {os.path.realpath(line[1:]) for line in done.stdout.splitlines() if line.startswith("n")}


def merged(sha: str) -> bool:
    return subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"],
                          capture_output=True).returncode == 0


def dead_tooling() -> list[str]:
    """Standalone tooling no other tracked code, config or test names (docs and ledgers do not count).
    Report-only: a common name can hide a dead file, never the other way round."""
    tracked = git("ls-files").splitlines()
    tooling = [p for p in tracked if (p.startswith(("scripts/", "tools/")) or "/scripts/" in p)
               and not p.endswith((".md", ".json", ".txt")) and not TEST_NAME.search(p.rsplit("/", 1)[-1])]

    def keys(path: str) -> set[str]:
        name = path.rsplit("/", 1)[-1]
        return {name, name[:-3]} if name.endswith(".py") else {name}
    names = set().union(*(keys(p) for p in tooling)) if tooling else set()
    if not names:
        return []
    pattern = re.compile("|".join(sorted((re.escape(n) for n in names), key=len, reverse=True)))
    seen: dict[str, set] = {}
    for path in tracked:
        if path.endswith(SKIP_SCAN):
            continue
        try:
            text = (ROOT / path).read_text(errors="ignore")
        except OSError:
            continue
        for name in set(pattern.findall(text)):
            seen.setdefault(name, set()).add(path)
    return [p for p in tooling if not (set().union(*(seen.get(k, set()) for k in keys(p))) - {p})]


def hook_drift() -> list[str]:
    """The installed pre-commit hook must be the one scripts/install-hooks.sh writes."""
    installer = ROOT / "scripts" / "install-hooks.sh"
    if not installer.exists():
        return []
    body = re.search(r"<< 'HOOK'\n(.*?\n)HOOK\n", installer.read_text(), re.S)
    hook = Path(git("rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit").strip())
    if body and (not hook.exists() or hook.read_text(errors="replace") != body.group(1)):
        return [f"{hook} is not the hook scripts/install-hooks.sh writes; run scripts/install-hooks.sh"]
    return []


def report(prune: bool) -> dict:
    trees = worktrees()
    primary = Path(trees[0]["worktree"])
    out: dict[str, list] = {k: [] for k in ("untracked", "residue", "tracked_ignored", "expired", "bytecode", "dead_tooling",
                                            "orphan_worktree_dirs", "hook", "worktrees", "branches", "notes", "pruned")}
    cwds = live_cwds()
    if cwds is None:
        out["notes"].append("lsof is unavailable; no worktree is pruned")

    for tree in [Path(w["worktree"]) for w in trees if not w.get("prunable")]:
        tops = {p.split("/", 1)[0] for p in git("ls-files", cwd=tree, check=False).splitlines()}
        status = git("status", "--porcelain", "--ignored", "--untracked-files=normal", cwd=tree, check=False)
        dirty = False
        for line in status.splitlines():
            code, rel = line[:2], unquote(line[3:]).rstrip("/")
            if code == "??":
                out["untracked"].append(str(tree / rel))
            elif code == "!!":
                for entry in ignored_entries(tree, rel):
                    if entry.endswith("__pycache__"):
                        out["bytecode"].append(str(tree / entry))
                    elif known(entry, tree) is None:
                        out["residue"].append(str(tree / entry))
                    if not entry.endswith("__pycache__") and known(entry, tree) != "regenerable":
                        dirty = True
            if code != "!!":
                dirty = True
        if tree == primary:
            out["tracked_ignored"] = tracked_ignored(tree)
        for entry in sorted(tree.iterdir()):
            if entry.is_dir() and entry.name not in tops | {".git"} and known(entry.name, tree) is None \
                    and not any(entry.iterdir()):
                out["residue"].append(str(entry))
        real = os.path.realpath(tree)
        if tree != primary and (dirty or cwds is None or any(c == real or c.startswith(real + os.sep) for c in cwds)):
            continue
        for folder, days in ((SCRATCH, SCRATCH_DAYS), (EVIDENCE, EVIDENCE_DAYS)):
            for base in [tree / folder, *tree.glob(f"packages/*/{folder}")]:
                if base.is_dir() and not base.is_symlink():
                    out["expired"] += [str(p) for p in sorted(base.iterdir()) if age_days(p) > days]
        pi = tree / PI_SCRATCH
        if pi.is_dir() and not pi.is_symlink():
            ignored = set(git("ls-files", "-o", "-i", "--exclude-standard", "--directory", "--", PI_SCRATCH,
                              cwd=tree, check=False).splitlines())
            out["expired"] += [str(tree / rel) for rel in sorted(ignored)
                               if pi_scratch(rel) and (tree / rel).is_file() and age_days(tree / rel) > SCRATCH_DAYS]

    for w in trees[1:]:
        path = Path(w["worktree"])
        branch = str(w.get("branch", "")).removeprefix("refs/heads/")
        status = git("status", "--porcelain", "--ignored", "--untracked-files=normal", cwd=path, check=False)
        dirty = any(not line.startswith("!! ") or known(unquote(line[3:]).rstrip("/"), path) != "regenerable"
                    for line in status.splitlines())
        real = os.path.realpath(path)
        live = cwds is None or any(c == real or c.startswith(real + os.sep) for c in cwds)
        out["worktrees"].append({"path": str(path), "branch": branch, "merged": merged(str(w.get("HEAD", ""))),
                                 "dirty": dirty, "live": live, "idleDays": activity_days(path),
                                 "evidence": len(uncopied_evidence(path, primary))})
    registered = {os.path.realpath(w["worktree"]) for w in trees}
    sibling = primary.parent / f"{primary.name}-worktrees"
    if sibling.is_dir():
        out["orphan_worktree_dirs"] = [str(e) for e in sorted(sibling.iterdir())
                                       if e.is_dir() and os.path.realpath(e) not in registered]

    checked_out = {str(w.get("branch", "")).removeprefix("refs/heads/") for w in trees}
    for line in git("for-each-ref", "--format=%(refname:short) %(objectname) %(committerdate:unix)", "refs/heads").splitlines():
        name, sha, when = line.split(" ")
        if name in PROTECTED_BRANCHES or name in checked_out:
            continue
        idle = round((time.time() - int(when)) / DAY)
        if merged(sha) or idle > BRANCH_IDLE_DAYS:
            out["branches"].append({"branch": name, "sha": sha, "merged": merged(sha), "idleDays": idle})

    out["dead_tooling"] = dead_tooling()
    out["hook"] = hook_drift()

    if prune:
        for path in map(Path, out["expired"] + out["bytecode"]):
            try:
                shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
            except OSError as error:
                out["notes"].append(f"could not delete {path}: {error.strerror or error}")
            if not path.exists() and not path.is_symlink():
                out["pruned"].append(str(path))
        for w in out["worktrees"]:
            if w["branch"] and w["merged"] and not w["dirty"] and not w["live"] and w["idleDays"] >= IDLE_DAYS and w["evidence"]:
                out["notes"].append(f"kept worktree {w['path']}: {w['evidence']} evidence file(s) the primary checkout lacks; "
                                    f"keep them with: rsync -a --ignore-existing {w['path']}/{EVIDENCE}/ {primary}/{EVIDENCE}/ "
                                    "(a same-named file with other content stays a decision)")
            elif w["branch"] and w["merged"] and not w["dirty"] and not w["live"] and w["idleDays"] >= IDLE_DAYS:
                try:
                    for directory, _, _ in os.walk(w["path"]):
                        os.chmod(directory, os.stat(directory).st_mode | stat.S_IWUSR)
                except OSError as error:
                    out["notes"].append(f"could not remove worktree {w['path']}: {error}")
                    continue
                removed = subprocess.run(["git", "-C", str(ROOT), "worktree", "remove", "--force", w["path"]],
                                         capture_output=True, text=True)
                if removed.returncode == 0:
                    out["pruned"].append(f"worktree {w['path']} (branch {w['branch']} is on main)")
                else:
                    out["notes"].append(f"could not remove worktree {w['path']}: {removed.stderr.strip()}")
        for b in out["branches"]:
            if b["merged"] and subprocess.run(["git", "-C", str(ROOT), "branch", "-d", b["branch"]],
                                              capture_output=True).returncode == 0:
                out["pruned"].append(f"branch {b['branch']} (restore: git branch {b['branch']} {b['sha']})")
        pruned = set(out["pruned"])
        for key in ("expired", "bytecode"):
            out[key] = [p for p in out[key] if p not in pruned]
    return out


FIXES = {
    "untracked": "commit it with an owner, move it to .scratch/, or delete it",
    "residue": "ignored path with no named writer: delete it, or name its writer in tools/ownership/tidy.py",
    "tracked_ignored": "tracked but matched by .gitignore; add a !negation for it, or untrack it",
    "expired": f"older than {SCRATCH_DAYS} days (scratch) or {EVIDENCE_DAYS} days (evidence): scripts/tron tidy --prune",
    "bytecode": "scripts/tron tidy --prune",
    "dead_tooling": "no code, config or test names it: add its scripts/tron subcommand or caller, or delete it",
    "orphan_worktree_dirs": "not a registered worktree: inspect it, then remove it by hand",
    "hook": "",
}


HERE_FIXES = {
    "untracked": "commit it with an owner, or delete it",
    "residue": "ignored path with no named writer: delete it, or name its writer in tools/ownership/tidy.py",
    "scratch": "your scratch: delete it before you report (keep evidence in test-results/ or the issue)",
    "subagent_worktrees": "a worktree your subagents left: remove it with `git worktree remove` and delete its branch",
}


def here(tree: Path) -> dict[str, list[str]]:
    """The residue one agent's worktree holds: what it must clean before it reports or parks.

    Untracked files and ignored paths no writer is named for, any `.scratch/` or loose `.pi/`
    entry (scratch is for the task, not after it), and worktrees registered under
    `<checkout>-worktrees/worktrees/<this worktree>/`, where pi-subagents places a delegated child's tree.
    """
    out: dict[str, list[str]] = {key: [] for key in HERE_FIXES}
    status = git("status", "--porcelain", "--ignored", "--untracked-files=normal", cwd=tree, check=False)
    for line in status.splitlines():
        code, rel = line[:2], unquote(line[3:]).rstrip("/")
        if code == "??":
            out["untracked"].append(rel)
        elif code == "!!":
            for entry in ignored_entries(tree, rel):
                if known(entry, tree) is None and not entry.endswith("__pycache__"):
                    out["residue"].append(entry)
    for folder in (tree / SCRATCH, *tree.glob(f"packages/*/{SCRATCH}")):
        if folder.is_dir() and not folder.is_symlink():
            out["scratch"] += [str(entry.relative_to(tree)) for entry in sorted(folder.iterdir())]
    pi = tree / PI_SCRATCH
    if pi.is_dir() and not pi.is_symlink():
        ignored = set(git("ls-files", "-o", "-i", "--exclude-standard", "--directory", "--", PI_SCRATCH,
                          cwd=tree, check=False).splitlines())
        out["scratch"] += sorted(rel for rel in ignored if pi_scratch(rel) and (tree / rel).is_file())
    primary = Path(worktrees()[0]["worktree"])
    children = os.path.realpath(primary.parent / f"{primary.name}-worktrees" / "worktrees" / tree.name)
    out["subagent_worktrees"] = [w["worktree"] for w in worktrees()
                                 if os.path.realpath(w["worktree"]).startswith(children + os.sep)]
    return out


def main(argv: list[str]) -> int:
    if "--here" in argv:
        if any(arg not in ("--here", "--json", "--landing") for arg in argv):
            print("usage: scripts/tron tidy --here [--landing] [--json]", file=sys.stderr)
            return 2
        tree = Path(git("rev-parse", "--show-toplevel", cwd=Path.cwd()).strip())
        found = here(tree)
        if "--landing" in argv:
            found = {key: items for key, items in found.items() if key in ("untracked", "residue")}
        count = sum(len(items) for items in found.values())
        if "--json" in argv:
            print(json.dumps({"worktree": str(tree), **found, "count": count}, indent=1))
            return 1 if count else 0
        for key, fix in HERE_FIXES.items():
            for item in found.get(key, []):
                print(f"tidy: {key}: {item} — {fix}")
        print(f"tidy: {tree}: {'clean' if not count else f'{count} item(s) to clean before you report'}")
        return 1 if count else 0
    if any(arg not in ("--json", "--prune") for arg in argv):
        print("usage: scripts/tron tidy [--json] [--prune] | --here [--json]", file=sys.stderr)
        return 2
    started = time.monotonic()
    result = report("--prune" in argv)
    drift = sum(len(result[key]) for key in FIXES) \
        + sum(1 for b in result["branches"] if not b["merged"] or "--prune" not in argv) \
        + sum(1 for w in result["worktrees"] if not w["merged"] and not w["live"] and w["idleDays"] > BRANCH_IDLE_DAYS) \
        + sum(1 for w in result["worktrees"] if w["merged"] and w["evidence"] and not w["live"] and w["idleDays"] >= IDLE_DAYS)
    if "--json" in argv:
        print(json.dumps({**result, "drift": drift, "seconds": round(time.monotonic() - started, 2)}, indent=1))
        return 1 if drift else 0
    for note in result["notes"]:
        print(f"tidy: {note}")
    for key, fix in FIXES.items():
        for item in result[key]:
            print(f"tidy: {key}: {item}" + (f" — {fix}" if fix else ""))
    for w in result["worktrees"]:
        state = ("merged" if w["merged"] else "unmerged") + (" dirty" if w["dirty"] else "") + (" live" if w["live"] else "") \
            + (f" {w['evidence']} evidence file(s) not in the primary checkout" if w["evidence"] else "")
        print(f"tidy: worktree {w['path']} [{w['branch']}] {state}, last activity {w['idleDays']}d ago")
    merged_count = sum(1 for b in result["branches"] if b["merged"])
    print(f"tidy: branches: {merged_count} merged into origin/main (--prune deletes them), "
          f"{len(result['branches']) - merged_count} unmerged and idle over {BRANCH_IDLE_DAYS}d (their owner decides)")
    for item in result["pruned"]:
        print(f"tidy: pruned {item}")
    print(f"tidy: {drift} item(s) need a decision ({time.monotonic() - started:.1f}s)")
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
