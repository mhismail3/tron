"""`work land` and `work steward`: update, verify, publish, wait, merge, hand off (README.md, `land`, `steward`)."""
from __future__ import annotations

import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import claim as claims
import start
import verify
from gh import Gh, GhError

# Issue forms prefix titles with "[Task]: "; claim.slugify drops it the same way.
_FORM_PREFIX = re.compile(r"^\s*\[[^\]]*\]:?\s*")
_SUMMARY = re.compile(r"^## Summary\n\n(.*?)\n\n## Verification\n", re.DOTALL | re.MULTILINE)
# Git's markers for an operation that has stopped half way.
_IN_PROGRESS = (("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"))
# How often land re-reads a pull request GitHub has just merged before giving up.
_MERGE_CONFIRMATIONS = 5

_STEWARD_PULLS = """
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 50, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body url headRefName isCrossRepository
        reviewThreads(first: 100) { nodes { isResolved } }
        commits(last: 1) {
          nodes {
            commit {
              oid committedDate
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    __typename
                    ... on CheckRun { name status conclusion }
                    ... on StatusContext { context state }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
"""


class LandError(RuntimeError):
    pass


# ---------------------------------------------------------------------- git


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if check and completed.returncode != 0:
        raise LandError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed


def _out(repo: Path, *args: str) -> str:
    return _git(repo, *args).stdout.strip()


def _is_ancestor(repo: Path, ancestor: str, head: str) -> bool:
    return _git(repo, "merge-base", "--is-ancestor", ancestor, head, check=False).returncode == 0


def operation_in_progress(root: Path) -> Optional[str]:
    for marker, name in _IN_PROGRESS:
        path = Path(_out(root, "rev-parse", "--path-format=absolute", "--git-path", marker))
        if path.exists():
            return name
    return None


def _dirty(root: Path) -> List[str]:
    return _out(root, "status", "--porcelain", "--untracked-files=all").splitlines()


def _fetch_base(root: Path, remote: str, base: str) -> str:
    _git(root, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
    return _out(root, "rev-parse", f"{remote}/{base}")


def _remote_head(root: Path, remote: str, branch: str) -> Optional[str]:
    line = _out(root, "ls-remote", remote, f"refs/heads/{branch}").split()
    return line[0] if line else None


def update_from_base(root: Path, remote: str, base: str) -> bool:
    """Merge the remote base tip into HEAD when HEAD lacks it; True when a merge was made."""
    tip = _fetch_base(root, remote, base)
    if _is_ancestor(root, tip, "HEAD"):
        return False
    # A merge, not a rebase: verify's carry-over needs the earlier receipt's
    # commit to stay an ancestor of the new head.
    merged = _git(root, "merge", "--no-edit", f"{remote}/{base}", check=False)
    if merged.returncode != 0:
        conflicts = _out(root, "diff", "--name-only", "--diff-filter=U").splitlines()
        detail = ("conflicts in: " + ", ".join(conflicts)) if conflicts else (merged.stderr or merged.stdout).strip()
        raise LandError(f"merging {remote}/{base} stopped; {detail}. Resolve and commit the merge, "
                        "then run land again. Nothing new was pushed.")
    return True


# ------------------------------------------------------------ GitHub state


def check_runs_state(contexts: List[dict], names: List[str]) -> Tuple[str, List[str]]:
    """'success', 'pending' or 'failure' for the named check runs, with each one's state."""
    states, details = [], []
    for name in names:
        runs = [c for c in contexts if c.get("__typename") == "CheckRun" and c.get("name") == name]
        if not runs:
            state, shown = "pending", "not reported"
        elif any(run.get("status") != "COMPLETED" for run in runs):
            state, shown = "pending", "running"
        elif all(run.get("conclusion") == "SUCCESS" for run in runs):
            state, shown = "success", "success"
        else:
            state = "failure"
            shown = ", ".join(sorted({str(run.get("conclusion")).lower() for run in runs}))
        states.append(state)
        details.append(f"{name}: {shown}")
    return _combine(states), details


def verify_state(contexts: List[dict], context: str) -> str:
    """'success', 'failure', 'pending', or 'missing' when the head has no such status."""
    found = [c.get("state") for c in contexts if c.get("__typename") == "StatusContext" and c.get("context") == context]
    if not found:
        return "missing"
    if found[-1] in ("PENDING", "EXPECTED"):
        return "pending"
    return "success" if found[-1] == "SUCCESS" else "failure"


def head_state(contexts: List[dict], config: dict) -> Tuple[str, List[str]]:
    """The merge gate on one head: every required check run and the verify status."""
    context = config["verify"]["statusContext"]
    checks, details = check_runs_state(contexts, config["land"]["requiredChecks"])
    status = verify_state(contexts, context)
    return _combine([checks, status]), details + [f"{context}: {status}"]


def _combine(states: List[str]) -> str:
    if "failure" in states:
        return "failure"
    return "success" if all(state == "success" for state in states) else "pending"


def _open_pull(gh: Gh, branch: str) -> Optional[dict]:
    pulls = json.loads(gh.run("pr", "list", "--head", branch, "--state", "open",
                              "--json", "number,title,body,url,isCrossRepository"))
    # Claim branch names are public; a fork can open a pull request with the same head name.
    own = sorted((p for p in pulls if not p["isCrossRepository"]), key=lambda p: p["number"])
    return own[0] if own else None


def _view(gh: Gh, number: int) -> dict:
    return json.loads(gh.run("pr", "view", str(number), "--json", "state,headRefOid,mergeCommit,statusCheckRollup"))


# ------------------------------------------------------------- public text


def _scrub(root: Path, config: dict, what: str, text: str) -> None:
    try:
        verify.scrub(root, config["verify"]["scrubCommand"], text)
    except verify.VerifyError as error:
        raise LandError(f"the scrub command refused the {what}; nothing was published\n{error}") from None


def default_title(branch: str, issue_title: str) -> str:
    return f"{branch.split('/', 1)[0]}: {_FORM_PREFIX.sub('', issue_title).strip()}"


def verification(receipt: dict) -> str:
    checks = receipt["checks"]
    required = receipt["required"]
    passed = sum(1 for name in required if checks[name]["exitCode"] == 0)
    carried = sum(1 for name in required if checks[name]["carriedFrom"])
    lines = [
        f"Verify receipt for `{receipt['head']}`: {passed}/{len(required)} required checks passed, "
        f"{carried} carried from an earlier commit whose inputs did not change. Base `{receipt['base']['ref']}` "
        f"at `{receipt['base']['sha'][:12]}`. The receipt comment has the commands and the evidence.",
        "",
        "| Check | Result | Wall time | Carried from |",
        "| --- | --- | --- | --- |",
    ]
    for name in required:
        entry = checks[name]
        result = "pass" if entry["exitCode"] == 0 else f"FAIL ({entry['exitCode']})"
        carried_from = f"`{entry['carriedFrom'][:12]}`" if entry["carriedFrom"] else ""
        lines.append(f"| {name} | {result} | {entry['seconds']}s | {carried_from} |")
    return "\n".join(lines)


def pull_body(keyword: str, number: int, summary: str, receipt: dict, action: Optional[str]) -> str:
    body = f"{keyword} #{number}\n\n## Summary\n\n{summary.strip()}\n\n## Verification\n\n{verification(receipt)}\n"
    if action is not None:
        # On GitHub before the merge, so a stop after the merge cannot lose it.
        body += f"\n## Maintainer validation\n\n{action.strip()}\n"
    return body


def _handoff(number: int, pull: int, merge_sha: str, action: str) -> str:
    return (f"<!-- work:needs-you pull={pull} -->\n"
            f"Merged in #{pull} as `{merge_sha[:12]}`. Waiting for maintainer-only validation:\n\n"
            f"{action.strip()}\n")


# ------------------------------------------------------------ merge + after


def merge(gh: Gh, pull: int, title: str, number: int, head: str, keyword: str,
          sleep: Callable[[float], None], poll: float) -> str:
    """Squash-merge exactly `head` and return the merge commit once GitHub reports MERGED."""
    subject = title if f"(#{number})" in title else f"{title} (#{number})"
    # --match-head-commit: GitHub refuses if the branch moved since it was checked.
    # Never --delete-branch: gh then checks out the base branch, which fails in a linked worktree.
    gh.run("pr", "merge", str(pull), "--squash", "--subject", subject, "--body", f"{keyword} #{number}",
           "--match-head-commit", head)
    for attempt in range(_MERGE_CONFIRMATIONS):
        view = _view(gh, pull)
        if view["state"] == "MERGED" and view.get("mergeCommit"):
            return view["mergeCommit"]["oid"]
        if attempt + 1 < _MERGE_CONFIRMATIONS:
            sleep(poll)
    raise LandError(f"GitHub accepted the merge of #{pull} but does not report it MERGED; "
                    "the branch and the issue were left as they are")


def delete_branch(root: Path, remote: str, branch: str, head: str) -> str:
    if _remote_head(root, remote, branch) is None:
        return "already deleted"
    # The lease keeps a branch that moved off the merged head, even just before this push.
    deleted = _git(root, "push", "-q", f"--force-with-lease=refs/heads/{branch}:{head}", remote,
                   f":refs/heads/{branch}", check=False)
    if deleted.returncode != 0:
        detail = (deleted.stderr.strip().splitlines() or ["no detail"])[-1]
        return f"kept: the delete with a lease on the merged head {head[:12]} was refused ({detail})"
    return "deleted"


def after_merge(gh: Gh, root: Path, config: dict, issue: dict, pull: int, merge_sha: str, head: str,
                branch: str, action: Optional[str]) -> None:
    try:
        _finish_issue(gh, root, config, issue, pull, merge_sha, head, branch, action)
    except (GhError, LandError, claims.ClaimError) as error:
        # Nothing reruns these steps: the claim branch may be gone, so name them.
        number, rules, settings = issue["number"], config["claim"], config["land"]
        if action is not None:
            steps = (f"reopen #{number} if it is closed, comment the validation text below on it, add the "
                     f"{settings['userValidationLabel']} label and set Status to "
                     f"{config['dashboard']['needsYouStatus']}")
        else:
            steps = f"close #{number} if it is open and set Status to {settings['doneStatus']}"
        message = (f"#{pull} merged as {merge_sha[:12]}, then finishing stopped: {error}\n"
                   f"Finish by hand: {steps}; delete {rules['remote']}/{branch} if it is still at {head[:12]}.")
        if action is not None:
            message += f"\nValidation text (also in #{pull}'s body):\n\n{action.strip()}"
        raise LandError(message) from None


def _finish_issue(gh: Gh, root: Path, config: dict, issue: dict, pull: int, merge_sha: str, head: str,
                  branch: str, action: Optional[str]) -> None:
    rules, settings = config["claim"], config["land"]
    owner, name = _repository(gh)
    current = start.load_issue(gh, owner, name, issue["number"], rules, config["project"]["title"])
    number = str(issue["number"])
    if action is not None:
        if current["state"] != "OPEN":
            gh.run("issue", "reopen", number)
        gh.run("issue", "comment", number, "--body-file", "-", stdin=_handoff(issue["number"], pull, merge_sha, action))
        gh.run("issue", "edit", number, "--add-label", settings["userValidationLabel"])
        target = config["dashboard"]["needsYouStatus"]
    else:
        # `Closes #N` did not always close the issue when this was done by hand.
        if current["state"] == "OPEN":
            gh.run("issue", "close", number, "--comment", f"Landed in #{pull} as `{merge_sha[:12]}`.")
        target = settings["doneStatus"]
    if current["item"] is not None and current["status"] != target:
        start.set_status(gh, current["item"], target)
    print(f"issue:    #{number} {'open, ' + target if action is not None else 'closed, ' + target}")
    print(f"branch:   {rules['remote']}/{branch} {delete_branch(root, rules['remote'], branch, head)}")


def _repository(gh: Gh) -> Tuple[str, str]:
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    return owner, name


# --------------------------------------------------------------------- land


def _wait(gh: Gh, config: dict, pull: int, head: str, sleep: Callable[[float], None],
          clock: Callable[[], float]) -> None:
    settings = config["land"]
    deadline = clock() + settings["waitSeconds"]
    shown = None
    while True:
        view = _view(gh, pull)
        if view["state"] != "OPEN":
            raise LandError(f"#{pull} is {view['state'].lower()}; nothing was merged")
        if view["headRefOid"] != head:
            state, details = "pending", [f"pull request head is {view['headRefOid'][:12]}, not {head[:12]}"]
        else:
            state, details = head_state(view["statusCheckRollup"] or [], config)
        if state == "failure":
            raise LandError(f"a required check failed on {head[:12]}; nothing was merged: " + "; ".join(details))
        if state == "success":
            return
        if clock() >= deadline:
            raise LandError(f"timed out after {settings['waitSeconds']}s waiting for: " + "; ".join(details)
                            + "; nothing was merged. Run land again to keep waiting.")
        if details != shown:
            print("waiting:  " + "; ".join(details), flush=True)
            shown = details
        sleep(settings["pollSeconds"])


def land(gh: Gh, repo: Path, config: dict, session_arg: Optional[str], title_arg: Optional[str],
         summary_path: Optional[Path], action: Optional[str],
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> int:
    rules, settings = config["claim"], config["land"]
    remote, base = rules["remote"], rules["baseBranch"]
    root = Path(_out(repo, "rev-parse", "--show-toplevel"))

    # Gates: everything that can refuse does so before the first GitHub write.
    branch = _git(root, "symbolic-ref", "-q", "--short", "HEAD", check=False).stdout.strip()
    if not branch:
        raise LandError("HEAD is detached; land runs on a claim branch")
    number = claims.claimed_issue(branch)
    if number is None:
        raise LandError(f"{branch} is not a claim branch (<type>/<issue>-<slug>)")
    operation = operation_in_progress(root)
    if operation:
        raise LandError(f"a {operation} is in progress; finish or abort it first")
    dirty = _dirty(root)
    if dirty:
        raise LandError("commit or remove local changes first:\n  " + "\n  ".join(dirty[:20]))
    session = start.session_of(session_arg)
    owned = [c for c in claims.existing_claims(root, remote, base, number) if c.branch == branch]
    if not owned:
        raise LandError(f"{remote}/{branch} does not exist; claim the issue with start first")
    if owned[0].session != session:
        raise LandError(f"{branch} is claimed by session {owned[0].session or 'unknown: no claim commit'}, "
                        f"not {session}")
    owner, name = _repository(gh)
    issue = start.load_issue(gh, owner, name, number, rules, config["project"]["title"])
    if issue["state"] != "OPEN":
        raise LandError(f"#{number} is closed")
    if issue["item"] is None:
        raise LandError(f"#{number} is not in the Project; add it back first")
    pull = _open_pull(gh, branch)
    if summary_path is not None:
        summary = summary_path.read_text()
    elif pull is not None and _SUMMARY.search((pull["body"] or "").replace("\r\n", "\n")):
        # A body saved from the web editor has CRLF line ends.
        summary = _SUMMARY.search(pull["body"].replace("\r\n", "\n")).group(1)
    else:
        raise LandError("--summary-file is required to open the pull request")
    title = title_arg or (pull["title"] if pull else default_title(branch, issue["title"]))
    _scrub(root, config, "title", title)
    _scrub(root, config, "summary", summary)
    if action is not None:
        # Checked now: after the merge a refusal would lose the handoff.
        _scrub(root, config, "validation text", action)
    keyword = "Refs" if action is not None else "Closes"

    for round_number in range(1, settings["maxRounds"] + 1):
        if update_from_base(root, remote, base):
            print(f"merged:   {remote}/{base} into {branch}")
        receipt = verify.verify(root, config)
        head = receipt["head"]
        if not receipt["passed"]:
            raise LandError(f"verify failed for {head[:12]}; nothing new was pushed or published")
        pushed = _git(root, "push", "-q", remote, f"HEAD:refs/heads/{branch}", check=False)
        if pushed.returncode != 0:
            raise LandError(f"push to {remote}/{branch} was refused: {pushed.stderr.strip()}")
        print(f"posted:   {verify.post(gh, root, config, receipt)}")

        # Every part of the body already passed the scrub: the title, summary and
        # validation text in the gates, the receipt fields in verify.post's comment.
        body = pull_body(keyword, number, summary, receipt, action)
        if pull is None:
            url = gh.run("pr", "create", "--base", base, "--head", branch, "--title", title, "--body-file", "-",
                         stdin=body).strip().splitlines()[-1]
            pull = {"number": int(url.rstrip("/").rsplit("/", 1)[1]), "url": url}
        else:
            gh.run("pr", "edit", str(pull["number"]), "--title", title, "--body-file", "-", stdin=body)
        print(f"pull:     {pull['url']}")
        if issue["status"] != settings["reviewStatus"]:
            start.set_status(gh, issue["item"], settings["reviewStatus"])
            issue["status"] = settings["reviewStatus"]

        _wait(gh, config, pull["number"], head, sleep, clock)
        # Without a branch rule that requires up-to-date branches, only this
        # check keeps a head that lacks the latest base from being merged.
        if not _is_ancestor(root, _fetch_base(root, remote, base), head):
            print(f"moved:    {remote}/{base} moved during round {round_number}; updating again")
            continue
        merge_sha = merge(gh, pull["number"], title, number, head, keyword, sleep, settings["pollSeconds"])
        print(f"merged:   #{pull['number']} as {merge_sha}")
        break
    else:
        raise LandError(f"{remote}/{base} moved in each of {settings['maxRounds']} rounds; nothing was merged. "
                        "Run land again.")

    after_merge(gh, root, config, issue, pull["number"], merge_sha, head, branch, action)
    primary = start.primary_checkout(root)
    removal = (f"git -C {primary} worktree remove {root} && " if root.resolve() != primary.resolve() else "")
    print(f"cleanup:  {removal}git -C {primary} branch -D {branch}")
    return 0


# ------------------------------------------------------------------ steward


def steward_rows(gh: Gh, repo: Path, config: dict) -> List[dict]:
    """Open pull requests from claim branches in this repository, with their merge-gate state."""
    rules = config["claim"]
    owner, name = _repository(gh)
    nodes: List[dict] = []
    cursor = None
    while True:
        page = gh.graphql(_STEWARD_PULLS, owner=owner, name=name, cursor=cursor)["repository"]["pullRequests"]
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        cursor = page["pageInfo"]["endCursor"]
    sessions = {c.branch: c.session for c in claims.all_claims(repo, rules["remote"], rules["baseBranch"])}
    local: Dict[str, Path] = {branch: path for path, branch in start.list_worktrees(repo).items() if branch}
    now = datetime.now(timezone.utc)
    rows = []
    for node in sorted(nodes, key=lambda n: n["number"]):
        number = claims.claimed_issue(node["headRefName"])
        if node["isCrossRepository"] or number is None:
            continue
        commits = node["commits"]["nodes"]
        commit = commits[-1]["commit"] if commits else {}
        contexts = ((commit.get("statusCheckRollup") or {}).get("contexts") or {}).get("nodes") or []
        committed = commit.get("committedDate")
        age = (now - datetime.fromisoformat(committed.replace("Z", "+00:00"))) if committed else None
        rows.append({
            "issue": number,
            "pr": node["number"],
            "title": node["title"],
            "body": node["body"] or "",
            "branch": node["headRefName"],
            "session": sessions.get(node["headRefName"]),
            "head": commit.get("oid"),
            "contexts": contexts,
            "checks": check_runs_state(contexts, config["land"]["requiredChecks"])[0],
            "verify": verify_state(contexts, config["verify"]["statusContext"]),
            "unresolved": sum(1 for t in node["reviewThreads"]["nodes"] if not t["isResolved"]),
            "head_age_hours": round(age.total_seconds() / 3600, 1) if age is not None else None,
            "worktree": local.get(node["headRefName"]),
        })
    return rows


def steward(gh: Gh, repo: Path, config: dict, number: Optional[int]) -> int:
    rows = steward_rows(gh, repo, config)
    if number is None:
        for row in rows:
            age = f"{row['head_age_hours']}h old" if row["head_age_hours"] is not None else "age unknown"
            print(f"#{row['issue']} PR #{row['pr']} {row['branch']} session {row['session'] or '?'} "
                  f"checks {row['checks']} verify {row['verify']} unresolved {row['unresolved']} head {age} "
                  f"{'worktree here' if row['worktree'] else 'no local worktree'}")
        print(f"{len(rows)} open pull request(s) from claim branches")
        return 0

    rules = config["claim"]
    remote, base = rules["remote"], rules["baseBranch"]
    root = Path(_out(repo, "rev-parse", "--show-toplevel"))
    matching = [row for row in rows if row["issue"] == number]
    if len(matching) != 1:
        raise LandError(f"expected one open pull request from a claim branch for #{number}, found {len(matching)}")
    row = matching[0]
    head, branch = row["head"], row["branch"]
    state, details = head_state(row["contexts"], config)
    if state != "success":
        raise LandError(f"#{row['pr']} is not ready at {head[:12]}: " + "; ".join(details))
    if not re.match(rf"Closes #{number}(?!\d)", row["body"] or ""):
        raise LandError(f"#{row['pr']} does not close #{number}; a validation handoff is its owner's to land")
    if _remote_head(root, remote, branch) != head:
        raise LandError(f"{remote}/{branch} is not at the pull request head {head[:12]}")
    _git(root, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}")
    if not _is_ancestor(root, _fetch_base(root, remote, base), head):
        raise LandError(f"{head[:12]} lacks the latest {remote}/{base}; the owner or a new claimant must update "
                        "and verify it")
    if row["worktree"] is not None:
        worktree = Path(row["worktree"])
        if _dirty(worktree) or _out(worktree, "rev-parse", "HEAD") != head:
            raise LandError(f"the worktree on {branch} has changes that are not in #{row['pr']}")
    owner, name = _repository(gh)
    issue = start.load_issue(gh, owner, name, number, rules, config["project"]["title"])
    if issue["state"] != "OPEN":
        raise LandError(f"#{number} is closed")
    merge_sha = merge(gh, row["pr"], row["title"], number, head, "Closes", time.sleep,
                      config["land"]["pollSeconds"])
    print(f"merged:   #{row['pr']} as {merge_sha}")
    after_merge(gh, root, config, issue, row["pr"], merge_sha, head, branch, None)
    return 0
