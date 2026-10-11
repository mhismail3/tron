"""Transfer an existing issue claim without replacing its worktree or files."""
from __future__ import annotations

import fcntl
from contextlib import contextmanager, ExitStack
import os
import re
import json
from pathlib import Path
import subprocess
import sys

import claim
from gh import Gh


class HandoffError(RuntimeError):
    pass


@contextmanager
def common_dir_lock(path: Path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


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
        if fields.get(claim.ISSUE_TRAILER) == str(number):
            return parts[0], fields.get(claim.SESSION_TRAILER)
    return None, None


def claimed_worktree(primary: Path, config: dict, branch: str) -> Path:
    worktree = (primary / config["claim"]["worktreeRoot"] / branch.split("/", 1)[1]).resolve()
    if not worktree.is_dir() or git(worktree, "rev-parse", "--show-toplevel") != str(worktree):
        raise HandoffError(f"claimed worktree is missing or invalid: {worktree}")
    registered = git(primary, "worktree", "list", "--porcelain")
    registered_paths = {line.removeprefix("worktree ") for line in registered.splitlines() if line.startswith("worktree ")}
    if str(worktree) not in registered_paths or Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve() != Path(git(primary, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve():
        raise HandoffError("claimed path is not a registered worktree of this repository")
    current_branch = git(worktree, "symbolic-ref", "--short", "HEAD")
    if current_branch != branch:
        raise HandoffError(f"claimed worktree is on {current_branch}, not {branch}")
    return worktree


def run(gh: Gh, cwd: Path, config: dict, number: int, new_session: str | None, force: bool, reason: str) -> int:
    if number < 1:
        raise HandoffError("issue number must be positive")
    session = claim_session(new_session)
    reason = reason.strip()
    if not reason or len(reason) > 500 or any(ord(char) < 32 for char in reason):
        raise HandoffError("reason must be 1–500 printable characters")
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    remote_heads = claim._remote_heads(cwd, remote)  # ls-remote is read-only; do not fetch before refusal checks
    matching = sorted((name, sha) for name, sha in remote_heads.items() if claim.claimed_issue(name) == number)
    if len(matching) != 1:
        raise HandoffError(f"expected exactly one claim branch for #{number}; found {len(matching)}")
    branch, remote_head = matching[0]
    primary = claim_repo_root(cwd)
    worktree = claimed_worktree(primary, config, branch)
    head = git(worktree, "rev-parse", "HEAD")
    if remote_head != head:
        # A remote object is not proof until cat-file succeeds. Exact trailers,
        # tree identity, and one-parent topology identify only our accepted commit.
        accepted = _handoff_trailers(worktree, remote_head, number) if _commit_exists(worktree, remote_head) else None
        parents = git(worktree, "rev-list", "--parents", "-n", "1", remote_head).split() if accepted else []
        tree = git(worktree, "rev-parse", f"{remote_head}^{{tree}}") if accepted else ""
        local_tree = git(worktree, "rev-parse", f"{head}^{{tree}}")
        if not (accepted and len(parents) == 2 and parents[1] == head and tree == local_tree
                and accepted.get(claim.SESSION_TRAILER) == session):
            raise HandoffError(f"local head {head} differs from remote claim head {remote_head}; use documented recover for a clean settled-owner descendant, otherwise preserve and inspect")
    _, old = _claim_at(worktree, head, number)
    # The issue number in the unique remote branch is the existing claim identity.
    # Legacy claims may have no claim commit (or no owner trailer); neither case
    # supplies an old session identity or evidence that its owner is dead.
    old = old or "unknown"
    if old == session:
        transition = _latest_handoff(worktree, head, number, session)
        if transition:
            commit, previous_owner, pre_head, prior_reason = transition
            _audit_comment(gh, number, previous_owner, session, pre_head, commit, prior_reason)
        print(f"claim #{number} already belongs to {session}")
        return 0
    # Known-owner lifecycle proof is intentionally conservative. The normal
    # runtime probe is provided by the gateway-backed helper when available.
    if not force:
        if old == "unknown":
            raise HandoffError("owner session is unknown; refusing handoff (maintainer may use --force-maintainer and confirm HANDOFF #<issue> FROM unknown)")
        state = owner_lifecycle(old)
        if state != "settled":
            raise HandoffError(f"owner session {old} is {state}; refusing handoff (maintainer may use --force-maintainer)")
    else:
        confirm(number, old)

    public_comment = (f"Claim handoff for #{number}: `{old}` → `{session}`.\n\n"
                      f"- Reason: {reason}\n- Pre-handoff head: `{head}`\n")
    scrub = config.get("verify", {}).get("scrubCommand")
    if not isinstance(scrub, str) or not scrub.strip():
        raise HandoffError("handoff requires the configured privacy guard")
    checked = subprocess.run(["bash", "-c", scrub], cwd=primary, input=public_comment, capture_output=True, text=True)
    if checked.returncode:
        raise HandoffError("handoff audit comment refused by the privacy guard")
    issue = gh.run("issue", "view", str(number), "--json", "state")
    if '"OPEN"' not in issue:
        raise HandoffError(f"issue #{number} is not open")
    git_dir = Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    if not git_dir.is_dir():
        raise HandoffError("repository common Git directory is unavailable")
    with common_dir_lock(git_dir):
        # This descriptor lock creates no repository file and never dirties an
        # otherwise-refused checkout.

        # Re-read both local and remote heads under lock; remote lease is the
        # cross-checkout concurrency fence.
        before = git(worktree, "rev-parse", "HEAD")
        for marker in ("MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"):
            worktree_marker = Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-path", marker))
            if worktree_marker.exists():
                raise HandoffError(f"refusing handoff while {marker} is in progress")
        if before != head:
            raise HandoffError("local head moved while preparing handoff")
        remote_heads = claim._remote_heads(worktree, remote)
        remote_head = remote_heads.get(branch)
        if remote_head != head:
            # Recover the only safe partial-acceptance shape: this exact local
            # handoff commit reached the remote, but local update-ref did not.
            if remote_head and subprocess.run(["git", "cat-file", "-e", f"{remote_head}^{{commit}}"], cwd=worktree).returncode == 0:
                parents = git(worktree, "rev-list", "--parents", "-n", "1", remote_head).split()
                trailers = _handoff_trailers(worktree, remote_head, number)
                tree = git(worktree, "rev-parse", f"{remote_head}^{{tree}}")
                local_tree = git(worktree, "rev-parse", f"{head}^{{tree}}")
                if (trailers and len(parents) == 2 and parents[1] == head and tree == local_tree
                        and trailers.get(claim.SESSION_TRAILER) == session
                        and trailers.get("Work-Handoff-From") == old
                        and trailers.get("Work-Handoff-Reason") == reason
                        and trailers.get("Work-Handoff-Pre-Head") == head):
                    git(worktree, "update-ref", f"refs/heads/{branch}", remote_head, head)
                    _audit_comment(gh, number, old, session, head, remote_head, reason)
                    print(f"recovered handoff #{number}: {old} → {session} at {remote_head}")
                    return 0
            raise HandoffError("remote claim moved; retry after inspecting the branch")
        message = (f"chore: handoff claim #{number}\n\n"
                   f"{claim.ISSUE_TRAILER}: {number}\n{claim.SESSION_TRAILER}: {session}\n"
                   f"Work-Handoff-From: {old}\nWork-Handoff-Reason: {reason}\nWork-Handoff-Pre-Head: {head}\n")
        tree = git(worktree, "rev-parse", "HEAD^{tree}")
        new_head = git(worktree, "commit-tree", tree, "-p", head, "-m", message)
        # A retry after remote acceptance repairs the local ref before emitting
        # another audit comment. The marker makes the public comment idempotent.
        pushed = subprocess.run(["git", "push", "--porcelain", f"--force-with-lease=refs/heads/{branch}:{head}",
                                 remote, f"{new_head}:refs/heads/{branch}"], cwd=worktree, capture_output=True, text=True)
        if pushed.returncode:
            raise HandoffError(f"remote claim update refused: {pushed.stderr.strip()}")
        git(worktree, "update-ref", f"refs/heads/{branch}", new_head, head)
        _audit_comment(gh, number, old, session, head, new_head, reason)
    print(f"handed off #{number}: {old} → {session} at {new_head}")
    return 0


@contextmanager
def candidate_locks(worktree: Path, branch: str):
    """Fence ordinary Git writers across the remote CAS; never remove foreign locks."""
    owned = []
    try:
        for target in (f"refs/heads/{branch}", "HEAD", "index"):
            path = Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-path", target + ".lock"))
            try:
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError as error:
                raise HandoffError(f"recovery refused: Git writer holds {target}") from error
            owned.append((path, fd))
        yield
    finally:
        for path, fd in reversed(owned):
            os.close(fd)
            path.unlink()


def recover(gh: Gh, cwd: Path, config: dict, number: int, expected_local: str, expected_remote: str, reason: str) -> int:
    """Reconcile unpublished work only; ordinary handoff still owns claim transfer."""
    if number < 1 or any(not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value)
                         for value in (expected_local, expected_remote)):
        raise HandoffError("recovery requires a positive issue and full expected commit IDs")
    if expected_local == expected_remote:
        raise HandoffError("recovery requires a strictly unpublished descendant; use handoff for equal heads")
    actor = claim_session(None)
    reason = reason.strip()
    if not reason or len(reason) > 500 or any(ord(char) < 32 for char in reason):
        raise HandoffError("reason must be 1–500 printable characters")
    primary = claim_repo_root(cwd)
    remote = config["claim"]["remote"]
    common = Path(git(primary, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    with common_dir_lock(common), ExitStack() as locks:
        matching = sorted((name, sha) for name, sha in claim._remote_heads(cwd, remote).items()
                          if claim.claimed_issue(name) == number)
        if len(matching) != 1:
            raise HandoffError(f"expected exactly one claim branch for #{number}; found {len(matching)}")
        branch, remote_head = matching[0]
        worktree = claimed_worktree(primary, config, branch)
        locks.enter_context(candidate_locks(worktree, branch))

        def check_local() -> None:
            if claimed_worktree(primary, config, branch) != worktree or git(worktree, "rev-parse", "HEAD") != expected_local:
                raise HandoffError("expected local head changed; recovery refused")
            for marker in ("MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"):
                if Path(git(worktree, "rev-parse", "--path-format=absolute", "--git-path", marker)).exists():
                    raise HandoffError(f"refusing recovery while {marker} is in progress")
            # A refusal must not refresh the caller's index as a side effect.
            if git(worktree, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all"):
                raise HandoffError("recovery requires a clean worktree and index")

        check_local()
        if remote_head not in (expected_remote, expected_local):
            raise HandoffError("expected remote head changed; recovery refused")
        if not _commit_exists(worktree, expected_remote) or subprocess.run(
                ["git", "merge-base", "--is-ancestor", expected_remote, expected_local],
                cwd=worktree, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            raise HandoffError("expected remote head is not an ancestor of the local candidate")
        prior_claim, old = _claim_at(worktree, expected_remote, number)
        if not old or (prior_claim, old) != _claim_at(worktree, expected_local, number):
            raise HandoffError("recovery requires the same known claim at both expected heads")
        if owner_lifecycle(old) != "settled":
            raise HandoffError(f"owner session {old} is live or unknown; refusing recovery")
        if json.loads(gh.run("issue", "view", str(number), "--json", "state")).get("state") != "OPEN":
            raise HandoffError(f"issue #{number} is not open")
        marker = f"<!-- work:recovery remote={expected_remote} candidate={expected_local} -->"
        body = (f"{marker}\nRecovered unverified candidate for #{number}. Ownership is unchanged.\n\n"
                f"- Settled owner: `{old}`\n- Recovery actor: `{actor}`\n- Reason: {reason}\n"
                f"- Expected remote ancestor: `{expected_remote}`\n- Preserved candidate: `{expected_local}`\n\n"
                "This is candidate publication, not acceptance or completion. Ordinary handoff and full land gates remain required.\n")
        scrub = config.get("verify", {}).get("scrubCommand")
        if not isinstance(scrub, str) or not scrub.strip() or subprocess.run(
                ["bash", "-c", scrub], cwd=primary, input=body, capture_output=True, text=True).returncode:
            raise HandoffError("recovery audit refused by the configured privacy guard")
        # Re-read authority and both heads after all potentially slow preparation.
        # The exact remote lease below is a CAS, never permission to rewrite:
        # strict ancestry was proven above and the pushed object is immutable.
        if owner_lifecycle(old) != "settled":
            raise HandoffError("owner settlement changed; recovery refused")
        check_local()
        current_heads = claim._remote_heads(worktree, remote)
        if sorted((name, sha) for name, sha in current_heads.items() if claim.claimed_issue(name) == number) != matching:
            raise HandoffError("remote claim changed while preparing recovery")
        if remote_head == expected_remote:
            result = subprocess.run(["git", "push", "--porcelain",
                f"--force-with-lease=refs/heads/{branch}:{expected_remote}", remote,
                f"{expected_local}:refs/heads/{branch}"], cwd=worktree, capture_output=True, text=True)
            if result.returncode:
                raise HandoffError(f"recovery publication refused; inspect exact heads before retry: {result.stderr.strip()}")
        # Also admits a retry after the exact candidate was accepted remotely but
        # its audit failed. No local ref/index rewrite or invented owner is needed.
        check_local()
        if claim._remote_heads(worktree, remote).get(branch) != expected_local:
            raise HandoffError("remote moved after candidate publication; inspect partial recovery")
        existing = gh.run("api", f"repos/{{owner}}/{{repo}}/issues/{number}/comments", "--paginate", "--jq", ".[].body")
        if marker not in existing:
            gh.run("issue", "comment", str(number), "--body-file", "-", stdin=body)
    print(f"recovered unverified candidate #{number}: {expected_remote} → {expected_local}; ownership unchanged; use handoff")
    return 0


def _commit_exists(repo: Path, commit: str) -> bool:
    return subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=repo,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def _handoff_trailers(repo: Path, commit: str, number: int) -> dict[str, str] | None:
    if not _commit_exists(repo, commit):
        return None
    body = git(repo, "show", "-s", "--format=%B", commit)
    trailers: dict[str, str] = {}
    for line in body.splitlines():
        key, marker, value = line.partition(":")
        if marker:
            if key.strip() in trailers:
                return None
            trailers[key.strip()] = value.strip()
    required = (claim.ISSUE_TRAILER, claim.SESSION_TRAILER, "Work-Handoff-From",
                "Work-Handoff-Reason", "Work-Handoff-Pre-Head")
    if trailers.get(claim.ISSUE_TRAILER) != str(number) or any(not trailers.get(key) for key in required):
        return None
    return trailers


def _latest_handoff(repo: Path, head: str, number: int, owner: str) -> tuple[str, str, str, str] | None:
    history = git(repo, "log", "--first-parent", f"--format=%H%x00%B%x1e", head)
    for record in history.split("\x1e"):
        commit, separator, body = record.strip().partition("\x00")
        if not separator:
            continue
        trailers = {}
        for line in body.splitlines():
            key, marker, value = line.partition(":")
            if marker:
                trailers[key.strip()] = value.strip()
        if (trailers.get(claim.ISSUE_TRAILER) == str(number)
                and trailers.get(claim.SESSION_TRAILER) == owner
                and trailers.get("Work-Handoff-From")
                and trailers.get("Work-Handoff-Reason")
                and trailers.get("Work-Handoff-Pre-Head")):
            return (commit, trailers["Work-Handoff-From"], trailers["Work-Handoff-Pre-Head"], trailers["Work-Handoff-Reason"])
    return None


def claim_session(explicit: str | None) -> str:
    value = explicit or os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID")
    if not value or not value.strip():
        raise HandoffError("no session identity: pass --session or set WORK_SESSION_ID")
    return value.strip()


def claim_repo_root(repo: Path) -> Path:
    common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent.resolve()


def _audit_comment(gh: Gh, number: int, old: str, new: str, head: str, transition: str, reason: str) -> None:
    marker = f"<!-- work:handoff commit={transition} -->"
    existing = gh.run("api", f"repos/{{owner}}/{{repo}}/issues/{number}/comments", "--paginate", "--jq", ".[].body")
    if marker in existing:
        return
    body = (f"{marker}\nClaim handoff for #{number}: `{old}` → `{new}`.\n\n"
            f"- Reason: {reason}\n- Pre-handoff head: `{head}`\n- Handoff commit: `{transition}`\n")
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
