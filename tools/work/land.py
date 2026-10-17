"""`work land`: check the branch once, then merge it in seconds (README.md#landing, #1190).

The branch's own plan runs on its exact commit outside any landing lock and records a
receipt keyed by its tree. Land then publishes the head and, holding only the merge
lock, checks that Git merges it cleanly onto the current base and squash-merges it
there. GitHub merges only the verified head (the merge names it). The combined result is
checked afterwards on main by the post-merge check (mainline.py), which stops landing
and reverts a culprit when the combination fails.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import List, Optional
from urllib.parse import quote

import claim as claims
import tracking
import gate
import ledger
import mainline
from gh import Gh, GhError

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
         repair_main: bool = False) -> int:
    branch = _current_branch(root, config["claim"]["baseBranch"])
    _event(root, "start", branch, dryRun=dry_run, tests=len(tests))
    try:
        result = _land(gh, root, config, title, summary_file, tests, dry_run, ready, publish_only, repair_main)
    except BaseException as error:
        _event(root, "failed", branch, error=type(error).__name__, detail=str(error).splitlines()[0][:200] if str(error) else "")
        raise
    _event(root, "finished", branch, dryRun=dry_run, publishOnly=publish_only)
    return result


def _refuse_if_stopped(root: Path, repair_main: bool) -> None:
    stop = mainline.stopped(root)
    if stop and not repair_main:
        raise LandError(mainline.stopped_message(stop))
    if stop:
        print(f"land: repairing main while {mainline.stopped_message(stop)}")


def _land(gh: Gh, root: Path, config: dict, title: Optional[str], summary_file: Path,
          tests: List[str], dry_run: bool, ready: bool = False, publish_only: bool = False,
          repair_main: bool = False) -> int:
    rules = config["claim"]
    remote, base = rules["remote"], rules["baseBranch"]
    branch = _current_branch(root, base)
    body = _summary(summary_file)
    number = claims.claimed_issue(branch)
    # The claimed issue names the change; the branch slug is only a fallback.
    if title is None and number:
        title = gh.rest("GET", f"repos/{_repository(gh)}/issues/{number}")["title"]
    _scrub(root, config["verify"]["scrubCommand"], (title or "") + "\n\n" + body)
    _refuse_if_stopped(root, repair_main)
    base_tip = _fetch_base(root, remote, base)
    head = _out(root, "rev-parse", "HEAD")
    if _out(root, "rev-list", "--count", f"{base_tip}..HEAD") == "0":
        raise LandError(f"nothing to land: {branch} has no commits beyond {remote}/{base}")
    conflicts = mainline.merges_cleanly(root, base_tip, head)
    if conflicts:
        raise LandError(_conflict_message(remote, base, branch, conflicts))

    # The branch check: its own tree, no landing lock (heavy admission still applies).
    verify_started = time.monotonic()
    receipt = gate.branch_check(root, config, tests, f"{remote}/{base}")
    _event(root, "verified", branch, ok=receipt is not None, seconds=round(time.monotonic() - verify_started, 1),
           baseTip=base_tip, receipt=(receipt or {}).get("tree"), receiptReused=(receipt or {}).get("reused"),
           **({} if (receipt or {}).get("reused") else gate.LAST_RUN))
    if receipt is None:
        raise LandError("the gate failed; nothing was pushed, opened or merged")
    if dry_run:
        print(f"dry run: {branch} at {head[:12]} verified (receipt for tree {receipt['tree'][:12]}); nothing pushed")
        if ready:
            print("  would mark the pull request ready for review first, if it is a draft")
        print(f"  would push {branch} to {remote}, open or update the pull request into {base}, "
              f"squash-merge it at {head[:12]} if it merges cleanly onto {remote}/{base}, delete {remote}/{branch}"
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
    if publish_only:
        print(f"published: PR #{pull['number']} at {head}; nothing merged, closed or deleted")
        return 0
    if pull.get("draft"):
        if not ready:
            raise LandError(f"pull request #{pull['number']} is a draft; rerun land with --ready to mark it "
                            "ready for review and merge. Nothing was merged.")
        _mark_ready(gh, repository, pull)

    # The critical section: no gate runs inside it, only the merge.
    with mainline.merge_lock(root, branch) as waited:
        _refuse_if_stopped(root, repair_main)
        base_tip = _fetch_base(root, remote, base)
        conflicts = mainline.merges_cleanly(root, base_tip, head)
        if conflicts:
            raise LandError(_conflict_message(remote, base, branch, conflicts))
        mainline.ensure_baseline(root, base_tip)
        try:
            merged = gh.rest("PUT", f"repos/{repository}/pulls/{pull['number']}/merge", {
                "merge_method": "squash",
                "sha": head,
                "commit_title": f"{pull['title']} (#{pull['number']})",
                "commit_message": body,
            })
        except GhError as error:
            raise LandError(f"GitHub refused the merge of #{pull['number']}: {error}") from error
    merge_sha = merged["sha"]
    _event(root, "merged", branch, pull=pull["number"], mergeSha=merge_sha, mergeWaitSeconds=waited,
           repairMain=repair_main or None, mainSyncs=_main_syncs(root, base_tip, head) if base == "main" else None)
    print(f"pull request #{pull['number']} squash-merged as {merge_sha}")
    mainline.start_background(root)
    print("main check: started in the background (scripts/tron gate status)")
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


def _conflict_message(remote: str, base: str, branch: str, conflicts: List[str]) -> str:
    return (f"{branch} does not merge cleanly onto {remote}/{base}; nothing was merged.\n"
            f"Merge {remote}/{base} into the branch, resolve these files, commit, then run land again:\n  "
            + "\n  ".join(conflicts[:30]))
