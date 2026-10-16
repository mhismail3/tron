"""`work land`: merge the base in, run the gate, push, squash-merge, close the issue (README.md, `land`).

There is no review or hosted-check gate: the local verify run on the exact commit
is the gate, and the squash merge names that commit, so GitHub merges only what
was verified.
"""
from __future__ import annotations

import json
import re
import subprocess
import time
from pathlib import Path
from typing import List, Optional
from urllib.parse import quote

import claim as claims
import tracking
import gate
import landqueue
import ledger
from gh import Gh, GhError

# A moved base sends land back to merging it, at most this many times. Landings through
# the queue (landqueue.py) never move it under each other; this covers a base moved
# outside the queue (an emergency maintainer push, a hosted merge).
MAX_LOOPBACKS = 3
MAX_PR_HEAD_OBSERVATIONS = 3
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


def _summary(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise LandError(f"cannot read the summary file: {error}") from error
    if not text.strip():
        raise LandError("the summary file is empty; it becomes the pull request body")
    return text


def _scrub(root: Path, command: str, text: str) -> None:
    """Public text (title and body) passes the privacy guard before any GitHub write."""
    checked = subprocess.run(["bash", "-c", command], cwd=root, input=text, capture_output=True, text=True)
    if checked.returncode:
        # The guard's output can quote personal data; it is not copied to the terminal.
        raise LandError("the privacy guard refused the pull request title or summary; nothing was pushed or posted")


def _fetch_base(root: Path, remote: str, base: str) -> str:
    _git(root, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    return _out(root, "rev-parse", f"{remote}/{base}")


def _is_ancestor(root: Path, ancestor: str, head: str) -> bool:
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, head], cwd=root,
                          capture_output=True).returncode == 0


def _integrate(root: Path, remote: str, base: str, tip: str, branch: str) -> None:
    """Merge the fetched base tip into the branch; a conflict is aborted and named for the agent to resolve."""
    if _is_ancestor(root, tip, "HEAD"):
        return
    merged = subprocess.run(["git", "merge", "--no-edit", tip], cwd=root, capture_output=True, text=True)
    if merged.returncode != 0:
        conflicts = _out(root, "diff", "--name-only", "--diff-filter=U").splitlines()
        subprocess.run(["git", "merge", "--abort"], cwd=root, capture_output=True)
        listing = "\n  ".join(conflicts) or merged.stderr.strip() or merged.stdout.strip()
        raise LandError(f"merging {remote}/{base} into {branch} conflicts; the merge was aborted.\n"
                        "Resolve these files on the branch, commit, then run land again:\n  " + listing)
    print(f"merged {remote}/{base} ({tip[:12]}) into {branch}")


def _repository(gh: Gh) -> str:
    return gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()


def _pull_request(gh: Gh, repository: str, branch: str, base: str, title: Optional[str],
                  body: str) -> dict:
    """The one open pull request for `branch` (opened or updated with the summary), from this repository."""
    owner = repository.split("/", 1)[0]
    open_pulls = gh.rest("GET", f"repos/{repository}/pulls?state=open&per_page=100&head={quote(f'{owner}:{branch}', safe=':')}")
    own = [p for p in open_pulls if (p["head"].get("repo") or {}).get("full_name") == repository]
    if own:
        return gh.rest("PATCH", f"repos/{repository}/pulls/{own[0]['number']}",
                       {"title": title or own[0]["title"], "body": body})
    return gh.rest("POST", f"repos/{repository}/pulls",
                   {"title": title or default_title(branch), "head": branch, "base": base, "body": body})


def _base_moved(root: Path, remote: str, base: str, head: str) -> bool:
    """Whether the base has moved past `head` since it was merged in (fetches the base again)."""
    return not _is_ancestor(root, _fetch_base(root, remote, base), head)


def _published_pull_request(gh: Gh, root: Path, repository: str, remote: str, branch: str,
                            head: str, pull: dict) -> dict:
    """Require current branch and PR heads to agree before merging a published head."""
    observed = pull
    for attempt in range(MAX_PR_HEAD_OBSERVATIONS):
        remote_result = _git(root, "ls-remote", "--heads", remote, f"refs/heads/{branch}", check=False)
        if remote_result.returncode != 0:
            raise LandError(f"could not confirm remote branch {branch} after publishing {head[:12]}; "
                            "publication state is uncertain; rerun land to observe it again")
        remote_fields = remote_result.stdout.split()
        remote_head = remote_fields[0] if remote_fields else None
        if remote_head != head:
            actual = remote_head[:12] if remote_head else "missing"
            raise LandError(f"remote branch {branch} is at {actual}, not the verified {head[:12]}; "
                            "the branch moved after land pushed it")
        if observed["head"]["sha"] == head:
            return observed
        if attempt + 1 < MAX_PR_HEAD_OBSERVATIONS:
            observed = gh.rest("GET", f"repos/{repository}/pulls/{observed['number']}")
    raise LandError(f"pull request #{pull['number']} still reports {observed['head']['sha'][:12]} after "
                    f"{MAX_PR_HEAD_OBSERVATIONS} observations while remote branch {branch} is at {head[:12]}; "
                    "publication state is uncertain; rerun land to observe it again")


def _mark_ready(gh: Gh, repository: str, pull: dict) -> None:
    """Clear draft state; the re-read must confirm it before any merge request is sent."""
    number = pull["number"]
    try:
        gh.mark_pull_request_ready(pull["node_id"])
    except GhError as error:
        raise LandError(f"GitHub refused to mark pull request #{number} ready for review: {error}; "
                        "nothing was merged") from error
    try:
        current = gh.rest("GET", f"repos/{repository}/pulls/{number}")
    except GhError as error:
        raise LandError(f"could not re-read pull request #{number} after marking it ready: {error}; "
                        "its ready state is uncertain; nothing was merged. Rerun land to observe it again") from error
    if current.get("draft") is not False:
        raise LandError(f"pull request #{number} is still a draft after marking it ready; its ready state is "
                        "uncertain; nothing was merged. Rerun land to observe it again")


def _finish_issue(gh: Gh, root: Path, config: dict, repository: str, number: int) -> str:
    """An issue with open sub-issues stays open: its children may still be unfinished scope."""
    open_children = tracking.open_sub_issues(gh, repository, number)
    if open_children:
        listing = ", ".join(f"#{child}" for child in open_children)
        return (f"left #{number} open: sub-issues {listing} remain open; "
                "close each fulfilled one with work issue close, then the epic")
    return tracking.complete_issue(gh, root, config, number)


def dispatch_ci(gh: Gh, root: Path, config: dict) -> int:
    """One explicit dispatch, never a retry; keep writes inside the audited Gh boundary."""
    remote, base = config["claim"]["remote"], config["claim"]["baseBranch"]
    branch = _current_branch(root, base)
    head = _out(root, "rev-parse", "HEAD")
    if _remote_head(root, remote, branch) != head:
        raise LandError("CI dispatch requires this exact head to be published first")
    repository = _repository(gh)
    workflow = config["dashboard"]["ciWorkflow"]
    gh.rest("POST", f"repos/{repository}/actions/workflows/{quote(workflow, safe='')}/dispatches", {"ref": branch})
    print(f"dispatched: {workflow} on {branch} at {head}; verify the run's headSha before counting it")
    return 0


def _main_syncs(root: Path, base_tip: str, head: str) -> Optional[int]:
    """Retain the baseline's PR-subject measure before squash/cleanup hides branch history."""
    try:
        subjects = _out(root, "log", f"{base_tip}..{head}", "--merges", "--format=%s").splitlines()
        count = 0
        for subject in subjects:
            named = re.match(r"^Merge (?:remote-tracking branch 'origin/main'|branch 'main'|origin/main\b|main\b)", subject)
            generic = re.match(r"^Merge commit ['\"]?([0-9a-f]{7,64})\b", subject)
            if named or (generic and _git(root, "merge-base", "--is-ancestor", generic.group(1), base_tip, check=False).returncode == 0):
                count += 1
        return count
    except (OSError, LandError):
        return None  # Missing history is unmeasured, not zero churn.


def _event(root: Path, event: str, branch: str, **fields) -> None:
    """One row in `<common>/work/land/events.jsonl` (ledger.py; `gate report` reads it)."""
    try:
        head = _out(root, "rev-parse", "HEAD")
        ledger.append(ledger.common_dir(root) / "work" / "land" / "events.jsonl", {
            **ledger.context(root), "event": event, "branch": branch, "issue": claims.claimed_issue(branch),
            "head": head, **fields})
    except (OSError, LandError, subprocess.CalledProcessError):
        pass  # The ledger observes landing; it never blocks or fails one.


def land(gh: Gh, root: Path, config: dict, title: Optional[str], summary_file: Path,
         tests: List[str], dry_run: bool, ready: bool = False, publish_only: bool = False,
         priority: str = "normal") -> int:
    branch = _current_branch(root, config["claim"]["baseBranch"])
    _event(root, "start", branch, dryRun=dry_run, tests=len(tests))
    try:
        if dry_run or publish_only:
            # Nothing merges, so nothing waits for the queue.
            result = _land(gh, root, config, title, summary_file, tests, dry_run, ready, publish_only)
        else:
            with landqueue.turn(root, branch, _out(root, "rev-parse", "HEAD"), priority) as waited:
                _event(root, "turn", branch, waitedSeconds=waited, priority=priority)
                result = _land(gh, root, config, title, summary_file, tests, dry_run, ready, publish_only)
    except BaseException as error:
        _event(root, "failed", branch, error=type(error).__name__, detail=str(error).splitlines()[0][:200] if str(error) else "")
        raise
    _event(root, "finished", branch, dryRun=dry_run, publishOnly=publish_only)
    return result


def _land(gh: Gh, root: Path, config: dict, title: Optional[str], summary_file: Path,
          tests: List[str], dry_run: bool, ready: bool = False, publish_only: bool = False) -> int:
    rules = config["claim"]
    remote, base = rules["remote"], rules["baseBranch"]
    branch = _current_branch(root, base)
    body = _summary(summary_file)
    number = claims.claimed_issue(branch)
    # The claimed issue names the change; the branch slug is only a fallback.
    if title is None and number:
        title = gh.rest("GET", f"repos/{_repository(gh)}/issues/{number}")["title"]
    _scrub(root, config["verify"]["scrubCommand"], (title or "") + "\n\n" + body)

    for loop in range(MAX_LOOPBACKS + 1):
        if loop:
            print(f"{remote}/{base} moved before the merge; merging it again")
            _event(root, "loop-back", branch, loop=loop)
        base_tip = _fetch_base(root, remote, base)
        if _out(root, "rev-list", "--count", f"{base_tip}..HEAD") == "0":
            raise LandError(f"nothing to land: {branch} has no commits beyond {remote}/{base}")
        before = _out(root, "rev-parse", "HEAD")
        _integrate(root, remote, base, base_tip, branch)
        head = _out(root, "rev-parse", "HEAD")
        if head != before:
            _event(root, "base-merged", branch, baseTip=base_tip)
        verify_started = time.monotonic()
        verified = gate.verify(root, config, tests, f"{remote}/{base}")
        _event(root, "verified", branch, ok=verified, seconds=round(time.monotonic() - verify_started, 1),
               baseTip=base_tip, **gate.LAST_RUN)
        if not verified:
            raise LandError("the gate failed; nothing was pushed, opened or merged")
        if dry_run:
            print(f"dry run: {branch} at {head[:12]} verified; nothing pushed")
            if ready:
                print("  would mark the pull request ready for review first, if it is a draft")
            print(f"  would push {branch} to {remote}, open or update the pull request into {base}, "
                  f"squash-merge it at {head[:12]}, delete {remote}/{branch}"
                  + (f" and close #{number} as completed with Status Done (left open while it has open sub-issues)"
                     if number else ""))
            return 0

        # A commit already merged from this branch is not landed again: a second pull request would duplicate it.
        landed = [p["number"] for p in merged_pulls(gh, branch) if p["headRefOid"] == head]
        if landed:
            raise LandError(f"#{landed[0]} already merged {head[:12]}; nothing to land. "
                            "Run work cleanup from this worktree.")
        if _remote_head(root, remote, branch) != head:
            _git(root, "push", remote, f"HEAD:refs/heads/{branch}")
        repository = _repository(gh)
        try:
            pull = _pull_request(gh, repository, branch, base, title, body)
        except GhError as error:
            raise LandError(f"could not open or update the pull request: {error}") from error
        pull = _published_pull_request(gh, root, repository, remote, branch, head, pull)
        if _base_moved(root, remote, base, head):
            continue
        if publish_only:
            print(f"published: PR #{pull['number']} at {head}; nothing merged, closed or deleted")
            return 0
        if pull.get("draft"):
            if not ready:
                raise LandError(f"pull request #{pull['number']} is a draft; rerun land with --ready to mark it "
                                "ready for review and merge. Nothing was merged.")
            _mark_ready(gh, repository, pull)
        final_title = pull["title"]
        try:
            merged = gh.rest("PUT", f"repos/{repository}/pulls/{pull['number']}/merge", {
                "merge_method": "squash",
                "sha": head,
                "commit_title": f"{final_title} (#{pull['number']})",
                "commit_message": body,
            })
        except GhError as error:
            if _base_moved(root, remote, base, head):
                continue
            raise LandError(f"GitHub refused the merge of #{pull['number']}: {error}") from error
        break
    else:
        raise LandError(f"{remote}/{base} kept moving; stopped after {MAX_LOOPBACKS} loop-backs. Run land again.")

    merge_sha = merged["sha"]
    _event(root, "merged", branch, pull=pull["number"], mergeSha=merge_sha,
           mainSyncs=_main_syncs(root, base_tip, head) if base == "main" else None)
    print(f"pull request #{pull['number']} squash-merged as {merge_sha}")
    try:
        print(f"branch:  {delete_branch(root, remote, branch, head)}")
        if number is not None:
            print(f"issue:   {_finish_issue(gh, root, config, repository, number)}")
    except (GhError, tracking.TrackingError, LandError) as error:
        raise LandError(f"merged as {merge_sha}, but the rest did not finish: {error}. "
                        f"Finish by hand: close #{number} with work issue close (it refuses an epic with open "
                        f"sub-issues), and delete {remote}/{branch} if it remains.") from error
    print(f"merged:  {merge_sha}")
    return 0
