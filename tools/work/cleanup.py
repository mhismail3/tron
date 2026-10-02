"""`work cleanup`: remove a task worktree and its branches once provably done (README.md, `cleanup`)."""
from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import claim as claims
import land
import start
from gh import Gh, GhError

# Enough of a long list to act on; the rest is counted.
_SHOWN = 20


class CleanupError(RuntimeError):
    pass


@dataclass
class Worktree:
    path: Path
    head: str
    branch: str  # '' when detached
    locked: Optional[str]  # the lock reason ('' without one), None when unlocked
    prunable: bool


@dataclass
class Settings:
    primary: Path
    root: Path
    remote: str
    base: str
    regenerable: List[str]  # git glob pathspecs
    releases: List[dict]
    started: Path  # the worktree (or checkout) cleanup was started from


# ---------------------------------------------------------------------- git


def _git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    completed = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise CleanupError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed


def list_worktrees(repo: Path) -> List[Worktree]:
    trees: List[Worktree] = []
    for record in _git(repo, "worktree", "list", "--porcelain", "-z").stdout.split("\0\0"):
        fields = [field for field in record.split("\0") if field]
        if not fields or not fields[0].startswith("worktree ") or "bare" in fields:
            continue
        values = dict(field.split(" ", 1) if " " in field else (field, "") for field in fields)
        branch = values.get("branch", "")
        trees.append(Worktree(
            path=Path(values["worktree"]).resolve(),
            head=values.get("HEAD", ""),
            branch=branch[len("refs/heads/"):] if branch.startswith("refs/heads/") else "",
            locked=values.get("locked"),
            prunable="prunable" in values,
        ))
    return trees


def _shown(lines: List[str]) -> str:
    more = f" and {len(lines) - _SHOWN} more" if len(lines) > _SHOWN else ""
    return ", ".join(lines[:_SHOWN]) + more


# ------------------------------------------------------------------- proofs


def _under_root(tree: Worktree, settings: Settings) -> bool:
    return settings.root in tree.path.parents


def _scope(tree: Worktree, settings: Settings) -> Optional[str]:
    """Why the worktree is not a cleanup candidate at all, or None."""
    if tree.path == settings.primary:
        return "the primary checkout is never cleaned up"
    if not _under_root(tree, settings):
        return "outside the worktree root"
    if tree.prunable or not tree.path.is_dir():
        return "its directory is missing; git worktree prune is the housekeeping procedure's"
    if not tree.branch:
        return "detached HEAD"
    if claims.claimed_issue(tree.branch) is None:
        return f"{tree.branch} is not a claim branch"
    if tree.locked is not None:
        return "locked" + (f": {tree.locked}" if tree.locked else "")
    return None


def _merged_head(gh: Gh, branch: str, head: str, base: str) -> Tuple[Optional[str], Optional[str]]:
    """(the pull request that merged exactly `head`, None) or (None, why none did)."""
    pulls = json.loads(gh.run("pr", "list", "--head", branch, "--state", "merged", "--limit", "100",
                              "--json", "number,headRefOid,baseRefName,isCrossRepository"))
    # Claim branch names are public; a fork can open a pull request with the same head name.
    own = [p for p in pulls if not p["isCrossRepository"] and p["baseRefName"] == base]
    for pull in own:
        if pull["headRefOid"] == head:
            return f"#{pull['number']}", None
    if own:
        merged = ", ".join(f"#{p['number']} at {p['headRefOid'][:12]}" for p in own)
        return None, f"merged {merged}, not at the local head {head[:12]}"
    others = [f"#{p['number']} into {p['baseRefName']}" for p in pulls
              if not p["isCrossRepository"] and p["baseRefName"] != base]
    return None, "no pull request from it is merged into " + base + (f" (merged {', '.join(others)})" if others else "")


def _local_blockers(tree: Worktree, settings: Settings) -> List[str]:
    """Why removing the worktree now could lose something that is not in its (merged) head."""
    path, reasons = tree.path, []
    current = _git(path, "rev-parse", "HEAD").stdout.strip()
    if current != tree.head:
        reasons.append(f"HEAD moved to {current[:12]} from {tree.head[:12]}")
    operation = land.operation_in_progress(path)
    if operation:
        reasons.append(f"a {operation} is in progress")
    dirty = _git(path, "status", "--porcelain", "--untracked-files=all").stdout.splitlines()
    if dirty:
        reasons.append(f"{len(dirty)} uncommitted or untracked: " + _shown([line[3:] for line in dirty]))
    # Every ignored file by name, not --directory: that folds an untracked directory holding only
    # ignored files into one `dir/` entry, hiding what is in it. Git prunes the regenerable globs.
    excluded = [f":(exclude,glob){glob}" for glob in settings.regenerable]
    kept = sorted(p for p in _git(path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--",
                                  ".", *excluded).stdout.split("\0") if p)
    if kept:
        reasons.append(f"{len(kept)} ignored and not regenerable: " + _shown(kept))
    return reasons


def _process_cwds() -> Tuple[Dict[int, int], List[Tuple[int, str, str]]]:
    """({pid: ppid}, [(pid, command, cwd)]) for every process lsof can see."""
    lsof = shutil.which("lsof")
    if lsof is None:
        raise CleanupError("lsof is not available")
    listed = subprocess.run([lsof, "-w", "-n", "-P", "-d", "cwd", "-F", "pRcn"], capture_output=True, text=True)
    if listed.returncode != 0:
        raise CleanupError(f"lsof failed: {listed.stderr.strip() or listed.returncode}")
    parents: Dict[int, int] = {}
    rows: List[Tuple[int, str, str]] = []
    pid, command = 0, ""
    for line in listed.stdout.splitlines():
        tag, value = line[:1], line[1:]
        if tag == "p":
            pid, command = int(value), ""
        elif tag == "R":
            parents[pid] = int(value)
        elif tag == "c":
            command = value
        elif tag == "n":
            rows.append((pid, command, value))
    return parents, rows


def _process_blockers(path: Path, settings: Settings) -> List[str]:
    try:
        parents, rows = _process_cwds()
    except CleanupError as error:
        return [f"cannot prove no process works inside: {error}"]
    # The caller's shell (and whatever launched it) may sit in the worktree it was started from.
    # Only there: an ancestor inside any other worktree is live work that `--all` must keep.
    exempt, pid = set(), (os.getpid() if path == settings.started else 0)
    while pid and pid not in exempt:
        exempt.add(pid)
        pid = parents.get(pid, 0)
    inside = [f"pid {pid} ({command})" for pid, command, cwd in rows
              if pid not in exempt and (cwd == str(path) or cwd.startswith(f"{path}/"))]
    return [f"working directory of {_shown(inside)}"] if inside else []


def _blockers(gh: Gh, tree: Worktree, settings: Settings) -> Tuple[Optional[str], List[str]]:
    """(the pull request that merged the head, every reason the worktree must stay)."""
    pull, why = _merged_head(gh, tree.branch, tree.head, settings.base)
    return pull, ([why] if why else []) + _local_blockers(tree, settings) + _process_blockers(tree.path, settings)


# ------------------------------------------------------------------ removal


def _release(path: Path, entry: dict) -> Optional[str]:
    """Run one release command inside the worktree; None when it succeeded, else why not."""
    with tempfile.TemporaryFile("w+") as output:
        # Output goes to a file: a detached grandchild holding a pipe would hang the read.
        process = subprocess.Popen(["bash", "-c", f"set -eo pipefail\n{entry['command']}"], cwd=path,
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        timed_out = False
        try:
            code = process.wait(timeout=entry["timeoutSeconds"])
        except BaseException as error:
            # The command owns a process group; a timeout or an interrupt leaves nothing of it running.
            timed_out = isinstance(error, subprocess.TimeoutExpired)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
            if not timed_out:
                raise
        output.seek(0)
        tail = "\n    ".join(output.read().strip().splitlines()[-_SHOWN:])
    if timed_out:
        return f"{entry['name']} timed out after {entry['timeoutSeconds']}s and was stopped\n    {tail}"
    if code != 0:
        return f"{entry['name']} exited {code}\n    {tail}"
    return None


def _drop_branch_settings(primary: Path, branch: str) -> str:
    """Remove the `branch.<name>` section `start --track` wrote; '' when none is left, else what was kept."""
    # update-ref, unlike `git branch -d`, leaves the section behind; names are compared exactly, not as a regex.
    names = _git(primary, "config", "--name-only", "--list").stdout.splitlines()
    if not any(n.startswith(f"branch.{branch}.") for n in names):
        return ""
    dropped = _git(primary, "config", "--remove-section", f"branch.{branch}", check=False)
    return "" if dropped.returncode == 0 else f", its settings kept ({dropped.stderr.strip()})"


def _remove(tree: Worktree, settings: Settings) -> Tuple[bool, str]:
    """Release, recheck, then remove the worktree, the local branch and the remote branch."""
    for entry in settings.releases:
        failure = _release(tree.path, entry)
        if failure:
            return False, f"release command {failure}"
    # The release commands take time; everything local is proven again right before removing.
    reasons = _local_blockers(tree, settings) + _process_blockers(tree.path, settings)
    if reasons:
        return False, "; ".join(reasons)
    removed = _git(settings.primary, "worktree", "remove", str(tree.path), check=False)
    if removed.returncode != 0:
        return False, f"git worktree remove refused: {removed.stderr.strip()}"
    # Only at the merged head: a branch moved since the check keeps its commits.
    deleted = _git(settings.primary, "update-ref", "-d", f"refs/heads/{tree.branch}", tree.head, check=False)
    if deleted.returncode == 0:
        local = "deleted" + _drop_branch_settings(settings.primary, tree.branch)
    else:
        local = f"kept ({deleted.stderr.strip()})"
    try:
        remote = land.delete_branch(settings.primary, settings.remote, tree.branch, tree.head)
    except land.LandError as error:
        return False, (f"worktree removed, local branch {local}; {settings.remote}/{tree.branch} was left: {error}. "
                       f"Delete it only if it is still at {tree.head[:12]}")
    return True, f"local branch {local}; {settings.remote}/{tree.branch} {remote}"


# ---------------------------------------------------------------------- run


def run(gh: Gh, cwd: Path, config: dict, all_worktrees: bool, dry_run: bool) -> int:
    rules, section = config["claim"], config["cleanup"]
    primary = start.primary_checkout(cwd).resolve()
    settings = Settings(
        primary=primary,
        root=(primary / rules["worktreeRoot"]).resolve(),
        remote=rules["remote"],
        base=rules["baseBranch"],
        regenerable=section["regenerableIgnored"],
        releases=section["releaseCommands"],
        started=Path(_git(cwd, "rev-parse", "--show-toplevel").stdout.strip()).resolve(),
    )
    trees = list_worktrees(primary)
    shown = primary.parent

    def name(tree: Worktree) -> str:
        return os.path.relpath(tree.path, shown)

    if all_worktrees:
        others = [t for t in trees if t.path != primary]
        outside = [t for t in others if not _under_root(t, settings)]
        candidates = sorted((t for t in others if _under_root(t, settings)), key=lambda t: t.path)
    else:
        candidates = [t for t in trees if t.path == settings.started]
        if not candidates:
            raise CleanupError(f"{settings.started} is not a registered worktree")
        reason = _scope(candidates[0], settings)
        if reason:
            raise CleanupError(f"{name(candidates[0])}: {reason}; nothing was touched")

    # Out of the way of the worktree being removed; every git call names its own directory.
    os.chdir(primary)
    # Under --all, one worktree's error (a failed gh call, a git failure) keeps that worktree
    # and the rest are still decided; for the current worktree alone it fails the command.
    errors = (CleanupError, GhError, land.LandError, json.JSONDecodeError, OSError) if all_worktrees else ()
    blocked = failed = done = 0
    for tree in candidates:
        label = name(tree)
        reason = _scope(tree, settings)
        if reason:
            print(f"kept:     {label}: {reason}")
            blocked += 1
            continue
        try:
            pull, reasons = _blockers(gh, tree, settings)
        except errors as error:
            pull, reasons = None, [f"cannot decide: {error}"]
        if reasons:
            print(f"kept:     {label} ({tree.branch}): " + "; ".join(reasons))
            blocked += 1
            continue
        if dry_run:
            releases = ", ".join(entry["name"] for entry in settings.releases) or "none"
            print(f"would remove: {label} ({tree.branch} at {tree.head[:12]}, {pull} merged); "
                  f"release commands: {releases}")
            done += 1
            continue
        try:
            ok, detail = _remove(tree, settings)
        except errors as error:
            ok, detail = False, f"error: {error}"
        if ok:
            print(f"removed:  {label} ({tree.branch} at {tree.head[:12]}, {pull} merged); {detail}")
            done += 1
        else:
            print(f"stopped:  {label} ({tree.branch}): {detail}")
            failed += 1

    if all_worktrees:
        root = os.path.relpath(settings.root, shown)
        print(f"{'would remove' if dry_run else 'removed'} {done}, kept {blocked}, stopped {failed} under {root}; "
              f"{len(outside)} worktree{'s' if len(outside) != 1 else ''} outside {root} left to the "
              "housekeeping procedure")
        return 1 if failed else 0
    if done and not dry_run:
        print(f"cd {primary}")
    return 0 if done else 1
