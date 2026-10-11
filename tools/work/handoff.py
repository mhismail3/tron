"""Transfer an existing issue claim without replacing its worktree or files."""
from __future__ import annotations

import fcntl
import os
from pathlib import Path
import subprocess
import sys

import claim
from gh import Gh


class HandoffError(RuntimeError):
    pass


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if check and result.returncode:
        raise HandoffError(f"git {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def confirm(number: int, old: str) -> None:
    if not sys.stdin.isatty():
        raise HandoffError("--force-maintainer requires an interactive terminal")
    expected = f"HANDOFF #{number} FROM {old}"
    print(f"Type exactly: {expected}")
    if input("> ").strip() != expected:
        raise HandoffError("confirmation did not match; claim unchanged")


def _claim_at(repo: Path, head: str, number: int) -> tuple[str | None, str | None]:
    trailers = ",".join(f"key={key}" for key in (claim.ISSUE_TRAILER, claim.SESSION_TRAILER))
    log = git(repo, "log", "--first-parent", f"--format=%H%x00%(trailers:{trailers},separator=%x1f)%x1e", head)
    for record in log.split("\x1e"):
        fields = {}
        parts = record.strip().split("\x00")
        if len(parts) < 2:
            continue
        for trailer in parts[1].split("\x1f"):
            key, _, value = trailer.partition(":")
            if value.strip():
                fields.setdefault(key.strip(), value.strip())
        if fields.get(claim.ISSUE_TRAILER) == str(number) and fields.get(claim.SESSION_TRAILER):
            return parts[0], fields[claim.SESSION_TRAILER]
    return None, None


def run(gh: Gh, cwd: Path, config: dict, number: int, new_session: str | None, force: bool) -> int:
    if number < 1:
        raise HandoffError("issue number must be positive")
    session = claim_session(new_session)
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    remote_heads = claim._remote_heads(cwd, remote)  # ls-remote is read-only; do not fetch before refusal checks
    matching = sorted((name, sha) for name, sha in remote_heads.items() if claim.claimed_issue(name) == number)
    if len(matching) != 1:
        raise HandoffError(f"expected exactly one claim branch for #{number}; found {len(matching)}")
    branch, remote_head = matching[0]
    primary = claim_repo_root(cwd)
    worktree = (primary / config["claim"]["worktreeRoot"] / branch.split("/", 1)[1]).resolve()
    if not worktree.is_dir() or git(worktree, "rev-parse", "--show-toplevel") != str(worktree):
        raise HandoffError(f"claimed worktree is missing or invalid: {worktree}")
    current_branch = git(worktree, "symbolic-ref", "--short", "HEAD")
    if current_branch != branch:
        raise HandoffError(f"claimed worktree is on {current_branch}, not {branch}")
    head = git(worktree, "rev-parse", "HEAD")
    if remote_head != head:
        raise HandoffError(f"local head {head} differs from remote claim head {remote_head}; synchronize manually")
    _, old = _claim_at(worktree, head, number)
    if not old:
        raise HandoffError(f"claim for #{number} has no valid owner trailer")
    if old == session:
        parent = git(worktree, "rev-parse", f"{head}^")
        _, previous_owner = _claim_at(worktree, parent, number)
        if previous_owner and previous_owner != session:
            _audit_comment(gh, number, previous_owner, session, parent)
        print(f"claim #{number} already belongs to {session}")
        return 0
    # Live/unknown lifecycle proof is intentionally conservative. The normal
    # runtime probe is provided by the gateway-backed helper when available.
    if not force:
        state = owner_lifecycle(old)
        if state != "settled":
            raise HandoffError(f"owner session {old} is {state}; refusing handoff (maintainer may use --force-maintainer)")
    else:
        confirm(number, old)

    issue = gh.run("issue", "view", str(number), "--json", "state")
    if '"OPEN"' not in issue:
        raise HandoffError(f"issue #{number} is not open")
    git_dir = Path(git(worktree, "rev-parse", "--git-common-dir")).resolve()
    lock_path = git_dir / "work" / "handoff.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        # Re-read both local and remote heads under lock; remote lease is the
        # cross-checkout concurrency fence.
        before = git(worktree, "rev-parse", "HEAD")
        if before != head:
            raise HandoffError("local head moved while preparing handoff")
        remote_heads = claim._remote_heads(worktree, remote)
        remote_head = remote_heads.get(branch)
        if remote_head != head:
            # Recover the only safe partial-acceptance shape: this exact local
            # handoff commit reached the remote, but local update-ref did not.
            if (remote_head and git(worktree, "cat-file", "-e", f"{remote_head}^{{commit}}", check=False) == ""
                    and git(worktree, "rev-parse", f"{remote_head}^", check=False) == head):
                recovered = _claim_at(worktree, remote_head, number)
                if recovered[1] == session:
                    git(worktree, "update-ref", f"refs/heads/{branch}", remote_head, head)
                    _audit_comment(gh, number, old, session, head)
                    print(f"recovered handoff #{number}: {old} → {session} at {remote_head}")
                    return 0
            raise HandoffError("remote claim moved; retry after inspecting the branch")
        message = (f"chore: handoff claim #{number}\n\n"
                   f"{claim.ISSUE_TRAILER}: {number}\n{claim.SESSION_TRAILER}: {session}\n")
        tree = git(worktree, "rev-parse", "HEAD^{tree}")
        new_head = git(worktree, "commit-tree", tree, "-p", head, "-m", message)
        # A retry after remote acceptance repairs the local ref before emitting
        # another audit comment. The marker makes the public comment idempotent.
        pushed = subprocess.run(["git", "push", "--porcelain", f"--force-with-lease=refs/heads/{branch}:{head}",
                                 remote, f"{new_head}:refs/heads/{branch}"], cwd=worktree, capture_output=True, text=True)
        if pushed.returncode:
            raise HandoffError(f"remote claim update refused: {pushed.stderr.strip()}")
        git(worktree, "update-ref", f"refs/heads/{branch}", new_head, head)
        _audit_comment(gh, number, old, session, head)
    print(f"handed off #{number}: {old} → {session} at {new_head}")
    return 0


def claim_session(explicit: str | None) -> str:
    value = explicit or os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID")
    if not value or not value.strip():
        raise HandoffError("no session identity: pass --session or set WORK_SESSION_ID")
    return value.strip()


def claim_repo_root(repo: Path) -> Path:
    common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent.resolve()


def _audit_comment(gh: Gh, number: int, old: str, new: str, head: str) -> None:
    marker = f"<!-- work:handoff issue={number} owner={new} -->"
    existing = gh.run("issue", "view", str(number), "--json", "comments", "--jq", ".comments[].body")
    if marker in existing:
        return
    body = (f"{marker}\nClaim handoff for #{number}: `{old}` → `{new}`.\n\n"
            f"- Reason: maintainer-approved claim handoff\n- Pre-handoff head: `{head}`\n")
    gh.run("issue", "comment", str(number), "--body-file", "-", stdin=body)


def owner_lifecycle(session: str) -> str:
    # Consult only the supported Home task RPC; ordinary sessions, unavailable
    # Home, and malformed/incomplete evidence remain indeterminate.
    root = Path(__file__).resolve().parents[2]
    helper = root / "packages/gateway/dist/client/work-owner-status.js"
    if not helper.is_file():
        return "unknown"
    try:
        result = subprocess.run(["node", str(helper), session], cwd=root, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() in {"settled", "live-or-indeterminate", "unknown"} else "unknown"
