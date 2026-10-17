"""Optional plain-Git landing and committed-review export. No tests, queue or receipts."""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import List, Optional

import claim as claims
from gh import Gh

_IN_PROGRESS = (("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"))


class LandError(RuntimeError):
    pass


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise LandError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed


def _out(repo: Path, *args: str) -> str:
    return _git(repo, *args).stdout.strip()


def operation_in_progress(root: Path) -> Optional[str]:
    for marker, name in _IN_PROGRESS:
        if Path(_out(root, "rev-parse", "--path-format=absolute", "--git-path", marker)).exists():
            return name
    return None


def merged_pulls(gh: Gh, branch: str) -> List[dict]:
    """Merged pull requests from `branch` in this repository, into any base, oldest first."""
    pulls = json.loads(gh.run("pr", "list", "--head", branch, "--state", "merged", "--limit", "100", "--json",
                              "number,headRefOid,baseRefName,isCrossRepository"))
    # Claim branch names are public; a fork can open a pull request with the same head name.
    return sorted((p for p in pulls if not p["isCrossRepository"]), key=lambda p: p["number"])


def _remote_head(root: Path, remote: str, branch: str) -> Optional[str]:
    output = _git(root, "ls-remote", "--heads", remote, f"refs/heads/{branch}").stdout.split()
    return output[0] if output else None


def delete_branch(root: Path, remote: str, branch: str, head: str) -> str:
    if _remote_head(root, remote, branch) is None:
        return "already deleted"
    # The lease keeps a branch that moved off the landed head, even just before this push.
    deleted = _git(root, "push", "-q", f"--force-with-lease=refs/heads/{branch}:{head}", remote,
                   f":refs/heads/{branch}", check=False)
    if deleted.returncode != 0:
        # GitHub deletes a merged head branch itself; a refusal because it is already gone is not a kept branch.
        if _remote_head(root, remote, branch) is None:
            return "already deleted"
        detail = (deleted.stderr.strip().splitlines() or ["no detail"])[-1]
        return f"kept: the delete with a lease on {head[:12]} was refused ({detail})"
    return "deleted"


def default_title(branch: str) -> str:
    """`<type>: <slug words>` from `<type>/<issue>-<slug>`, for a pull request opened without --title."""
    kind, _, rest = branch.partition("/")
    words = rest.split("-", 1)[1] if "-" in rest and rest.split("-", 1)[0].isdigit() else rest
    return f"{kind}: {words.replace('-', ' ')}"


def _current_branch(root: Path, base: str) -> str:
    branch = subprocess.run(["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=root,
                            capture_output=True, text=True).stdout.strip()
    if not branch:
        raise LandError("HEAD is detached; land from a task branch")
    if branch == base:
        raise LandError(f"never land from {base}; commit on a task branch in its own worktree")
    operation = operation_in_progress(root)
    if operation:
        raise LandError(f"a {operation} is in progress; finish or abort it first")
    dirty = _out(root, "status", "--porcelain", "--untracked-files=all").splitlines()
    if dirty:
        raise LandError("commit or remove local changes first:\n  " + "\n  ".join(dirty[:20]))
    return branch


def export_review(root: Path, config: dict, output: Path, base_ref: Optional[str]) -> int:
    """Export immutable committed Git evidence, independent of a reviewer's cwd."""
    branch = _current_branch(root, config["claim"]["baseBranch"])
    head = _out(root, "rev-parse", "HEAD")
    reference = base_ref or f"{config['claim']['remote']}/{config['claim']['baseBranch']}"
    bases = _out(root, "merge-base", "--all", reference, head).splitlines()
    if len(bases) != 1:
        raise LandError("review needs exactly one merge base; provide an unambiguous --base ref")
    base = bases[0]
    tree = _out(root, "rev-parse", f"{head}^{{tree}}")
    diff = subprocess.run(["git", "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base, head, "--"],
                          cwd=root, capture_output=True)
    if diff.returncode:
        raise LandError("cannot export committed diff: " + diff.stderr.decode(errors="replace"))
    patch = diff.stdout
    if not patch:
        raise LandError("no committed changes to review against the selected base")
    stat = _out(root, "diff", "--stat", "--no-ext-diff", "--no-textconv", base, head, "--")
    # Local edits never enter the patch, but refuse a racing author checkout rather
    # than implying its current change is the immutable commit named by the export.
    if _current_branch(root, config["claim"]["baseBranch"]) != branch or _out(root, "rev-parse", "HEAD") != head:
        raise LandError("the author branch changed during export; retry on a stable committed tree")
    header = f"Tron committed review\nBase: {base}\nHead: {head}\nTree: {tree}\nBranch: {branch}\n\n{stat}\n\n"
    payload = header.encode() + patch
    guarded = subprocess.run(["bash", str(root / "scripts/personal-info-guard.sh"), "--stdin"],
                             cwd=root, input=payload, capture_output=True)
    if guarded.returncode:
        raise LandError("review export refused by the privacy guard: " + guarded.stderr.decode(errors="replace"))
    created = False
    try:
        with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
            created = True
            stream.write(payload)
    except OSError as error:
        if created:
            output.unlink(missing_ok=True)
        raise LandError(f"cannot create review artifact {output}: {error}; choose a new output path") from error
    print(f"review: {output.resolve()}\nhead: {head}\nbase: {base}\ntree: {tree}")
    return 0



def land(root: Path, config: dict, dry_run: bool = False) -> int:
    """Fetch, merge main into this branch, and push HEAD without force or retries.

    A competing push is Git's normal non-fast-forward failure, not a reservation.
    Leave conflicts and rejected candidates in the worker's worktree for resolution.
    """
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    branch = _current_branch(root, base)
    _git(root, "config", "rerere.enabled", "true")
    # Remote-tracking refs are shared by linked worktrees; FETCH_HEAD is not.
    # Empty refmap prevents fetch's opportunistic tracking-ref update, so a
    # sibling fetch cannot invalidate this worker's fetched merge snapshot.
    _git(root, "fetch", "--no-tags", "--refmap=", remote, f"refs/heads/{base}")
    if dry_run:
        print(f"would merge fetched {remote}/{base} (FETCH_HEAD) into {branch}; git push {remote} HEAD:refs/heads/{base}")
        return 0
    _git(root, "merge", "--no-edit", "FETCH_HEAD")
    _git(root, "push", remote, f"HEAD:refs/heads/{base}")
    print(f"landed: {_out(root, 'rev-parse', 'HEAD')} on {remote}/{base}")
    return 0
