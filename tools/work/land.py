"""`work land`: merge the base in, verify, push, squash-merge, close the issue (README.md, `land`).

There is no review or hosted-check gate: the local verify run on the exact commit
is the gate, and the squash merge names that commit, so GitHub merges only what
was verified.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import List, Optional
from urllib.parse import quote

import claim as claims
import tracking
import verify
from gh import Gh, GhError

# A moved base sends land back to merging it, at most this many times.
MAX_LOOPBACKS = 3
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


def land(gh: Gh, root: Path, config: dict, title: Optional[str], summary_file: Path,
         tests: List[str], dry_run: bool) -> int:
    rules = config["claim"]
    remote, base = rules["remote"], rules["baseBranch"]
    branch = _current_branch(root, base)
    body = _summary(summary_file)
    _scrub(root, config["verify"]["scrubCommand"], (title or "") + "\n\n" + body)
    number = claims.claimed_issue(branch)

    for loop in range(MAX_LOOPBACKS + 1):
        if loop:
            print(f"{remote}/{base} moved before the merge; merging it again")
        base_tip = _fetch_base(root, remote, base)
        if _out(root, "rev-list", "--count", f"{base_tip}..HEAD") == "0":
            raise LandError(f"nothing to land: {branch} has no commits beyond {remote}/{base}")
        _integrate(root, remote, base, base_tip, branch)
        head = _out(root, "rev-parse", "HEAD")
        if not verify.verify(root, config, tests, f"{remote}/{base}"):
            raise LandError("verify failed; nothing was pushed, opened or merged")
        if dry_run:
            print(f"dry run: {branch} at {head[:12]} verified; nothing pushed")
            print(f"  would push {branch} to {remote}, open or update the pull request into {base}, "
                  f"squash-merge it at {head[:12]}, delete {remote}/{branch}"
                  + (f" and close #{number} as completed with Status Done" if number else ""))
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
        if pull["head"]["sha"] != head:
            raise LandError(f"pull request #{pull['number']} is at {pull['head']['sha'][:12]}, not {head[:12]}; "
                            "someone else pushed to this branch")
        if _base_moved(root, remote, base, head):
            continue
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
    print(f"pull request #{pull['number']} squash-merged as {merge_sha}")
    try:
        print(f"branch:  {delete_branch(root, remote, branch, head)}")
        if number is not None:
            print(f"issue:   {tracking.complete_issue(gh, root, config, number)}")
    except (GhError, tracking.TrackingError, LandError) as error:
        raise LandError(f"merged as {merge_sha}, but the rest did not finish: {error}. "
                        f"Finish by hand: close #{number} as completed, set its Status to Done, "
                        f"and delete {remote}/{branch} if it remains.") from error
    print(f"merged:  {merge_sha}")
    return 0
