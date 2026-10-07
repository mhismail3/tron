"""`work land` and `work steward`: update, verify, publish, wait, merge, hand off (README.md, `land`, `steward`)."""
from __future__ import annotations

import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import acceptance
import claim as claims
import start
import verify
from gh import Gh, GhError

# Issue forms prefix titles with "[Task]: "; claim.slugify drops it the same way.
_FORM_PREFIX = re.compile(r"^\s*\[[^\]]*\]:?\s*")
_SUMMARY = re.compile(r"^## Summary\n\n(.*?)\n\n## Verification\n", re.DOTALL | re.MULTILINE)
_VALIDATION = "\n## Maintainer validation\n\n"
_BUG_SUMMARY_SECTIONS = ("Repro", "Cause", "Fix")
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
        number title body url headRefName baseRefName isCrossRepository
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


def merged_pulls(gh: Gh, branch: str) -> List[dict]:
    """Merged pull requests from `branch` in this repository, into any base, oldest first."""
    pulls = json.loads(gh.run("pr", "list", "--head", branch, "--state", "merged", "--limit", "100", "--json",
                              "number,body,headRefOid,baseRefName,mergeCommit,isCrossRepository"))
    # Claim branch names are public; a fork can open a pull request with the same head name.
    return sorted((p for p in pulls if not p["isCrossRepository"]), key=lambda p: p["number"])


def _merged_pull(gh: Gh, branch: str, head: str, base: str) -> Optional[dict]:
    """The pull request from `branch` in this repository that GitHub merged into `base` at exactly `head`."""
    return next((p for p in merged_pulls(gh, branch) if p["baseRefName"] == base and p["headRefOid"] == head), None)


def _view(gh: Gh, number: int) -> dict:
    return json.loads(gh.run("pr", "view", str(number), "--json",
                             "state,headRefOid,baseRefName,mergeCommit,statusCheckRollup"))


# ------------------------------------------------------------- public text


def _scrub(root: Path, config: dict, what: str, text: str) -> None:
    try:
        verify.scrub(root, config["verify"]["scrubCommand"], text)
    except verify.VerifyError as error:
        raise LandError(f"the scrub command refused the {what}; nothing was published\n{error}") from None


def default_title(branch: str, issue_title: str) -> str:
    return f"{branch.split('/', 1)[0]}: {_FORM_PREFIX.sub('', issue_title).strip()}"


def validation_handoff(action: Optional[str], irreducible: Optional[str]) -> Optional[str]:
    """The Maintainer validation section: what no journey can prove, then the check itself.

    A handoff without its irreducible part asks the maintainer to redo work an
    acceptance journey could have done, so the two flags travel together; a flag
    whose value is blank counts as absent rather than naming anything.
    """
    action, irreducible = _given(action), _given(irreducible)
    if action is None and irreducible is None:
        return None
    if irreducible is None:
        raise LandError('--needs-user-validation requires --irreducible "<part>": name the part no '
                        "acceptance journey can prove")
    if action is None:
        raise LandError("--irreducible names the part of a --needs-user-validation handoff that no "
                        "acceptance journey can prove")
    return f"Irreducible: {irreducible}\n\n{action}"


def _given(value: Optional[str]) -> Optional[str]:
    """A flag's value, or None when it is absent or blank."""
    stripped = value.strip() if isinstance(value, str) else None
    return stripped or None


def verification(receipt: dict, evidence_link: Optional[str] = None) -> str:
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
    if evidence_link:
        lines += ["", *verify.media_links(receipt, evidence_link)]
    return "\n".join(lines)


def acceptance_evidence(records: List[dict]) -> str:
    """The acceptance half of the Verification section: one passing journey per line.

    The reports stay local, because they name this machine's paths; the body
    carries each one's sha256 and the fields that make it judgeable.
    """
    lines = ["### Acceptance journeys", "",
             "Each journey ran against this head; the digest is the sha256 of the `report.json` "
             "that run left:", ""]
    for record in records:
        lines.append(f"- `{record['journey']}`: passed in {record['seconds']}s; evidence complete; "
                     f"{record['artifacts']} artifact(s); report sha256 `{record['sha256']}`; "
                     f"source `{record['revision']}` fingerprint `{record['fingerprint']}`.")
    return "\n".join(lines)


def _visible_markdown(text: str) -> Tuple[List[str], List[bool], bool, bool]:
    """Blank HTML comments and fence delimiters while retaining code payload and line positions."""
    visible: List[str] = []
    code_lines: List[bool] = []
    fence: Optional[Tuple[str, int]] = None
    in_comment = False
    for line in text.replace("\r\n", "\n").splitlines():
        fence_match = re.match(r" {0,3}(`{3,}|~{3,})", line)
        if not in_comment and fence_match:
            marker = fence_match.group(1)
            if fence is None:
                fence = (marker[0], len(marker))
                visible.append("")
                code_lines.append(False)
                continue
            remainder = line[fence_match.end():]
            if marker[0] == fence[0] and len(marker) >= fence[1] and not remainder.strip(" \t"):
                fence = None
                visible.append("")
                code_lines.append(False)
                continue
        if fence is not None:
            visible.append(line)
            code_lines.append(True)
            continue

        output: List[str] = []
        cursor = 0
        while cursor < len(line):
            if in_comment:
                end = line.find("-->", cursor)
                if end < 0:
                    output.append(" " * (len(line) - cursor))
                    cursor = len(line)
                else:
                    output.append(" " * (end + 3 - cursor))
                    cursor = end + 3
                    in_comment = False
            else:
                start = line.find("<!--", cursor)
                if start < 0:
                    output.append(line[cursor:])
                    cursor = len(line)
                else:
                    output.append(line[cursor:start])
                    end = line.find("-->", start + 4)
                    if end < 0:
                        output.append(" " * (len(line) - start))
                        cursor = len(line)
                        in_comment = True
                    else:
                        output.append(" " * (end + 3 - start))
                        cursor = end + 3
        visible.append("".join(output))
        code_lines.append(False)
    return visible, code_lines, fence is None, not in_comment


def _markdown_headings(text: str) -> Tuple[List[Tuple[str, int, int]], bool, bool]:
    """Return ATX heading depth/title/line outside comments and fenced code."""
    lines, code_lines, balanced_fence, balanced_comment = _visible_markdown(text)
    headings: List[Tuple[str, int, int]] = []
    for index, line in enumerate(lines):
        if code_lines[index]:
            continue
        match = re.fullmatch(r" {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*", line)
        if match:
            headings.append((match.group(2).strip(), len(match.group(1)), index))
    return headings, balanced_fence, balanced_comment


def _has_meaningful_content(lines: List[Tuple[str, bool]]) -> bool:
    for line, is_code in lines:
        if not is_code and re.match(r"^ {0,3}#{1,6}[ \t]+", line):
            continue
        # Blank lines, Markdown delimiters, and empty list/table scaffolding are not evidence.
        payload = re.sub(r"[\s#>*_~`|!()\[\]{}+\-]", "", line)
        if payload:
            return True
    return False


def validate_issue_summary(summary: str, labels: List[str]) -> None:
    """Require meaningful, ordered bug evidence before any landing writes."""
    if "kind:bug" not in labels:
        return
    lines, code_lines, balanced_fence, balanced_comment = _visible_markdown(summary)
    headings, _, _ = _markdown_headings(summary)
    required = {name: [] for name in _BUG_SUMMARY_SECTIONS}
    sections: Dict[str, List[Tuple[str, bool]]] = {name: [] for name in _BUG_SUMMARY_SECTIONS}
    reserved: List[str] = []
    for title, depth, index in headings:
        if depth != 2:
            continue
        if title in ("Summary", "Verification", "Maintainer validation"):
            reserved.append(title)
        elif title in required:
            required[title].append(index)
    heading_at = {index: (title, depth) for title, depth, index in headings}
    current: Optional[str] = None
    for index, line in enumerate(lines):
        if current is not None and index not in heading_at:
            sections[current].append((line, code_lines[index]))
        if index in heading_at:
            title, depth = heading_at[index]
            if depth <= 2:
                current = title if depth == 2 and title in required else None
    # The loop above assigns content following each required heading, stopping at every H1/H2.
    absent = [name for name in _BUG_SUMMARY_SECTIONS if len(required[name]) != 1]
    positions = [required[name][0] for name in _BUG_SUMMARY_SECTIONS if len(required[name]) == 1]
    ordered = len(positions) == len(_BUG_SUMMARY_SECTIONS) and positions == sorted(positions)
    empty = [name for name in _BUG_SUMMARY_SECTIONS if len(required[name]) == 1
             and not _has_meaningful_content(sections[name])]
    if absent or empty or not ordered or reserved or not balanced_fence or not balanced_comment:
        reasons = absent + [name for name in empty if name not in absent]
        if not ordered and not absent:
            reasons.append("sections in Repro, Cause, Fix order")
        if reserved:
            reasons.append("generated heading(s): " + ", ".join(reserved))
        if not balanced_fence:
            reasons.append("unclosed fenced example")
        if not balanced_comment:
            reasons.append("unclosed HTML comment")
        raise LandError("bug summary requires exactly one meaningful `## Repro`, `## Cause`, and `## Fix` "
                        "section in order before the generated `## Verification`; " + ", ".join(reasons))


def _markdown_h2_sections(text: str) -> Tuple[List[Tuple[str, int]], bool, bool]:
    """Return top-level H2 headings outside comments/fences, with line indexes."""
    headings, balanced_fence, balanced_comment = _markdown_headings(text)
    return [(title, index) for title, depth, index in headings if depth == 2], balanced_fence, balanced_comment


def validate_existing_bug_body(body: str, labels: List[str], pull: int) -> None:
    """Validate an adopted or merged bug PR body, not just its parsed prefix."""
    if "kind:bug" not in labels:
        return
    text = (body or "").replace("\r\n", "\n")
    headings, balanced_fence, balanced_comment = _markdown_h2_sections(text)
    summaries = [index for title, index in headings if title == "Summary"]
    verifications = [index for title, index in headings if title == "Verification"]
    if (not balanced_fence or not balanced_comment or len(summaries) != 1 or len(verifications) != 1
            or summaries[0] >= verifications[0]):
        raise LandError(f"#{pull} bug pull request must have one Summary and one generated Verification section")
    summary = "\n".join(text.splitlines()[summaries[0] + 1:verifications[0]])
    validate_issue_summary(summary, labels)


def pull_body(keyword: str, number: int, summary: str, receipt: dict, action: Optional[str],
              evidence_link: Optional[str] = None,
              acceptance_records: Optional[List[dict]] = None) -> str:
    body = f"{keyword} #{number}\n\n## Summary\n\n{summary.strip()}\n\n## Verification\n\n{verification(receipt, evidence_link)}\n"
    if acceptance_records:
        body += f"\n{acceptance_evidence(acceptance_records)}\n"
    if action is not None:
        # On GitHub before the merge, so a stop after the merge cannot lose it.
        body += f"\n## Maintainer validation\n\n{action.strip()}\n"
    return body


def merge_intent(pull: int, body: str, number: int) -> Tuple[str, Optional[str]]:
    """The keyword a body written by pull_body merges with, and its validation text (None for Closes)."""
    text = (body or "").replace("\r\n", "\n")  # a body saved from the web editor has CRLF line ends
    keyword = re.match(rf"(Closes|Refs) #{number}(?!\d)", text)
    if keyword is None:
        raise LandError(f"#{pull} neither closes nor refers to #{number}")
    headings, _, _ = _markdown_h2_sections(text)
    summary_index = next((index for title, index in headings if title == "Summary"), None)
    verification_index = next((index for title, index in headings
                               if title == "Verification" and (summary_index is None or index > summary_index)), None)
    handoff_index = next((index for title, index in headings
                          if title == "Maintainer validation" and verification_index is not None
                          and index > verification_index), None)
    action = None
    if handoff_index is not None:
        lines = text.splitlines()
        action = "\n".join(lines[handoff_index + 1:]).strip() or None
    if keyword.group(1) == "Refs" and not action:
        raise LandError(f"#{pull} refers to #{number} but has no Maintainer validation text to hand off")
    if keyword.group(1) == "Closes" and action is not None:
        raise LandError(f"#{pull} closes #{number} but also has a Maintainer validation section")
    return keyword.group(1), action


def _handoff_marker(pull: int) -> str:
    # #334 types this marker with the handoff's runner and its deployment
    # prerequisite; until then the format is unchanged, and a second marker
    # format would orphan every existing handoff.
    return f"<!-- work:needs-you pull={pull} -->"


def _handoff(pull: int, merge_sha: str, action: str) -> str:
    return (f"{_handoff_marker(pull)}\n"
            f"Merged in #{pull} as `{merge_sha[:12]}`. Waiting for maintainer-only validation:\n\n"
            f"{action.strip()}\n")


# ------------------------------------------------------------ merge + after


def merge(gh: Gh, pull: int, title: str, number: int, head: str, keyword: str, base: str,
          sleep: Callable[[float], None], poll: float) -> str:
    """Squash-merge exactly `head` into `base` and return the merge commit once GitHub reports MERGED."""
    subject = title if f"(#{number})" in title else f"{title} (#{number})"
    # The base is read again at the merge: a pull request retargeted while checks
    # ran must not land elsewhere. GitHub's merge call takes no expected base, so
    # a retarget in the moment between this read and the merge is not caught.
    current = _view(gh, pull)["baseRefName"]
    if current != base:
        raise LandError(f"#{pull} now merges into {current}, but its claim lands into {base}; nothing was merged")
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
        return f"kept: the delete with a lease on {head[:12]} was refused ({detail})"
    return "deleted"


# ------------------------------------------------------ merged PR CI runs


def cancel_stale_runs(gh: Gh, repository: str, head: str, branch: str) -> None:
    """Cancel the merged pull request's queued or in-progress runs for `head`.

    Once GitHub merged the pull request, its own runs cannot supersede the base
    push run's result and their macOS jobs hold the queue later lands need. Only
    runs of the `pull_request` event from the merged branch at exactly the merged
    head may be touched.
    This is best effort: the merge already happened, so a listing or cancellation
    failure is reported and never raised.
    """
    try:
        listed = gh.rest("GET", f"repos/{repository}/actions/runs?head_sha={head}&event=pull_request&per_page=100")
        runs = listed.get("workflow_runs") if isinstance(listed, dict) else None
        if not isinstance(runs, list):
            raise ValueError("the response holds no workflow_runs list")
    except (GhError, ValueError) as error:
        print(f"warning:  CI runs for {head[:12]} were not listed: {error}")
        return
    for run in runs:
        # The query filters both, and this refuses anything else the response holds.
        if (not isinstance(run, dict) or run.get("head_sha") != head or run.get("event") != "pull_request"
                or run.get("head_branch") != branch):
            continue
        if run.get("status") == "completed":
            continue
        try:
            gh.rest("POST", f"repos/{repository}/actions/runs/{run['id']}/cancel")
        except (GhError, ValueError, KeyError) as error:
            print(f"warning:  CI run {run.get('id')} for {head[:12]} was not cancelled: {error}")
        else:
            print(f"ci:       run {run['id']} for {head[:12]} cancelled")


def after_merge(gh: Gh, root: Path, config: dict, issue: dict, pull: int, merge_sha: str, head: str,
                branch: str, action: Optional[str], resumable: bool, base: str) -> None:
    try:
        owner, name = _repository(gh)
        repository = f"{owner}/{name}"
        cancel_stale_runs(gh, repository, head, branch)
        _finish_issue(gh, root, config, repository, issue, pull, merge_sha, head, branch, action, base)
    except (GhError, LandError, claims.ClaimError) as error:
        # Only land, rerun from the merged head's worktree, resumes these steps; name them for everyone else.
        number, rules, settings = issue["number"], config["claim"], config["land"]
        if action is not None:
            steps = (f"reopen #{number} if it is closed, comment the validation text below on it, add the "
                     f"{settings['userValidationLabel']} label and set Status to "
                     f"{config['dashboard']['needsYouStatus']}")
        else:
            steps = f"close #{number} if it is open and set Status to {settings['doneStatus']}"
        message = f"#{pull} merged as {merge_sha[:12]}, then finishing stopped: {error}\n"
        if resumable:
            message += f"Run land again from this worktree at {head[:12]} to finish, or finish by hand: "
        else:
            message += "Finish by hand: "
        message += f"{steps}; delete {rules['remote']}/{branch} if it is still at {head[:12]}."
        if action is not None:
            message += f"\nValidation text (also in #{pull}'s body):\n\n{action.strip()}"
        raise LandError(message) from None


def _finish_issue(gh: Gh, root: Path, config: dict, repository: str, issue: dict, pull: int, merge_sha: str,
                  head: str, branch: str, action: Optional[str], base: str) -> None:
    state = _finish_issue_state(gh, config, repository, issue, pull, merge_sha, action, base)
    print(f"issue:    #{issue['number']} {state}")
    # A claim may have started from this branch after the last check before the merge.
    owner, name = repository.split("/", 1)
    stacked = _open_stacked(gh, root, config, owner, name, branch)
    deleted = (f"kept: open claim(s) start from it: {_named(stacked)}" if stacked
               else delete_branch(root, config["claim"]["remote"], branch, head))
    print(f"branch:   {config['claim']['remote']}/{branch} {deleted}")


def _finish_issue_state(gh: Gh, config: dict, repository: str, issue: dict, pull: int, merge_sha: str,
                        action: Optional[str], base: str) -> str:
    """Close the issue or hand it off, unless a finished earlier run's outcome was since changed by hand."""
    rules, settings = config["claim"], config["land"]
    owner, name = repository.split("/", 1)
    current = start.load_issue(gh, owner, name, issue["number"], rules, config["project"]["title"])
    number = str(issue["number"])
    if action is not None:
        # The reopen comes before the handoff comment, so with the marker present an
        # earlier run reopened the issue: closed now, it is the maintainer's close.
        handed_off = any(_handoff_marker(pull) in comment for comment in current["comments"])
        if handed_off and current["state"] != "OPEN":
            return f"was handed off in #{pull} and closed since; left as it is"
        if current["state"] != "OPEN":
            gh.run("issue", "reopen", number)
        if not handed_off:
            gh.run("issue", "comment", number, "--body-file", "-", stdin=_handoff(pull, merge_sha, action))
        gh.run("issue", "edit", number, "--add-label", settings["userValidationLabel"])
        target, outcome = config["dashboard"]["needsYouStatus"], "open"
    else:
        landed = f"Landed in #{pull} as"
        # Only an earlier run closes with this comment: open now, it is the maintainer's reopen.
        if current["state"] == "OPEN" and any(comment.startswith(landed) for comment in current["comments"]):
            return f"was closed for #{pull} and reopened since; left as it is"
        # `Closes #N` did not always close the issue when this was done by hand, and
        # GitHub applies it only to the default branch: land closes a stacked claim's
        # issue itself, and names the branch it landed into.
        into = "" if base == rules["baseBranch"] else f" into `{base}`"
        if current["state"] == "OPEN":
            gh.run("issue", "close", number, "--comment", f"{landed} `{merge_sha[:12]}`{into}.")
        target, outcome = settings["doneStatus"], "closed"
    if current["item"] is not None and current["status"] != target:
        start.set_status(gh, current["item"], target)
    return f"{outcome}, {target}"


def _repository(gh: Gh) -> Tuple[str, str]:
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    return owner, name


# --------------------------------------------------------------------- land


def run_acceptance(config: dict, root: Path, journeys: List[str]) -> List[dict]:
    """Run the named journeys against the head land is about to verify, and keep their reports.

    They run before the receipt: a journey that fails, or a report that does not
    name this head, stops land before anything is pushed, posted or merged. The
    text published from the reports passes the scrub command here, before the
    first write.
    """
    head = _out(root, "rev-parse", "HEAD")
    records = [acceptance.run(config, root, head, journey) for journey in journeys]
    _scrub(root, config, "acceptance evidence", acceptance_evidence(records))
    return records


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
         summary_path: Optional[Path], action: Optional[str], irreducible: Optional[str] = None,
         acceptance_arg: Optional[str] = None, sleep: Callable[[float], None] = time.sleep,
         clock: Callable[[], float] = time.monotonic, evidence_manifest: Optional[Path] = None) -> int:
    rules, settings = config["claim"], config["land"]
    remote = rules["remote"]
    root = Path(_out(repo, "rev-parse", "--show-toplevel"))

    # Gates: everything that can refuse does so before the first GitHub write.
    section = validation_handoff(action, irreducible)
    journeys = acceptance.requested(config, acceptance_arg) if acceptance_arg is not None else []
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
    head = _out(root, "rev-parse", "HEAD")
    # The claim lands where it started: its recorded base (README.md, `start`).
    base = claims.claim_base(root, remote, rules["baseBranch"], "HEAD", number)
    merged = _merged_pull(gh, branch, head, base)
    if merged is not None:
        return _resume(gh, root, config, branch, number, session, head, merged, section, base)
    owned = [c for c in claims.existing_claims(root, remote, rules["baseBranch"], number) if c.branch == branch]
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
    pull = verify.open_pull(gh, branch)
    if pull is not None and pull["baseRefName"] != base:
        raise LandError(f"#{pull['number']} merges into {pull['baseRefName']}, but {branch} lands into {base}; "
                        "retarget or close that pull request first")
    _refuse_stacked(gh, root, config, owner, name, branch)
    if summary_path is not None:
        summary = summary_path.read_text()
    elif pull is not None and "kind:bug" in issue["labels"]:
        validate_existing_bug_body(pull["body"], issue["labels"], pull["number"])
        body_lines = pull["body"].replace("\r\n", "\n").splitlines()
        headings, _, _ = _markdown_h2_sections(pull["body"].replace("\r\n", "\n"))
        summary_index = next(index for title, index in headings if title == "Summary")
        verification_index = next(index for title, index in headings if title == "Verification")
        summary = "\n".join(body_lines[summary_index + 1:verification_index])
    elif pull is not None and _SUMMARY.search((pull["body"] or "").replace("\r\n", "\n")):
        # A body saved from the web editor has CRLF line ends.
        summary = _SUMMARY.search(pull["body"].replace("\r\n", "\n")).group(1)
    else:
        raise LandError("--summary-file is required to open the pull request")
    title = title_arg or (pull["title"] if pull else default_title(branch, issue["title"]))
    _scrub(root, config, "title", title)
    _scrub(root, config, "summary", summary)
    validate_issue_summary(summary, issue["labels"])
    if section is not None:
        # Checked now: after the merge a refusal would lose the handoff.
        _scrub(root, config, "validation text", section)
    keyword = "Refs" if section is not None else "Closes"

    for round_number in range(1, settings["maxRounds"] + 1):
        if update_from_base(root, remote, base):
            print(f"merged:   {remote}/{base} into {branch}")
        records = run_acceptance(config, root, journeys) if journeys else []
        receipt = verify.verify(root, config, evidence_manifest)
        head = receipt["head"]
        if not receipt["passed"]:
            raise LandError(f"verify failed for {head[:12]}; nothing new was pushed or published")
        pushed = _git(root, "push", "-q", remote, f"HEAD:refs/heads/{branch}", check=False)
        if pushed.returncode != 0:
            raise LandError(f"push to {remote}/{branch} was refused: {pushed.stderr.strip()}")
        print(f"posted:   {verify.post(gh, root, config, receipt)}")

        # Every part of the body already passed the scrub: the title, summary,
        # validation text and acceptance evidence in the gates, the receipt
        # fields in verify.post's comment.
        evidence_link = f"../../{name}{config['verify']['evidenceRepositorySuffix']}/tree/HEAD/{number}/{head}"
        body = pull_body(keyword, number, summary, receipt, section, evidence_link, records)
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
        # Checked again here: a claim may have started from this branch during the wait.
        _refuse_stacked(gh, root, config, owner, name, branch)
        merge_sha = merge(gh, pull["number"], title, number, head, keyword, base, sleep, settings["pollSeconds"])
        print(f"merged:   #{pull['number']} as {merge_sha}")
        break
    else:
        raise LandError(f"{remote}/{base} moved in each of {settings['maxRounds']} rounds; nothing was merged. "
                        "Run land again.")

    after_merge(gh, root, config, issue, pull["number"], merge_sha, head, branch, section, resumable=True, base=base)
    print("cleanup:  run `work cleanup` from this worktree once you are done in it")
    return 0


def _open_stacked(gh: Gh, root: Path, config: dict, owner: str, name: str, branch: str) -> List[claims.Claim]:
    """Claims of open issues that start from `branch`; a stacked claim whose issue is closed no longer counts."""
    rules = config["claim"]
    return [c for c in claims.stacked_on(root, rules["remote"], rules["baseBranch"], branch)
            if start.load_issue(gh, owner, name, claims.claimed_issue(c.branch), rules,
                                config["project"]["title"])["state"] == "OPEN"]


def _named(stacked: List[claims.Claim]) -> str:
    return ", ".join(f"#{claims.claimed_issue(c.branch)} ({c.branch})" for c in stacked)


def _refuse_stacked(gh: Gh, root: Path, config: dict, owner: str, name: str, branch: str) -> None:
    """Refuse to land `branch` while an open issue's claim starts from it (README.md, failure mode 77).

    Landing deletes the remote branch, which would leave those claims nothing to land into.
    """
    stacked = _open_stacked(gh, root, config, owner, name, branch)
    if stacked:
        raise LandError(f"{len(stacked)} open claim(s) start from {branch}: {_named(stacked)}; "
                        "land them into it, or close their issues, first")


def _resume(gh: Gh, root: Path, config: dict, branch: str, number: int, session: str, head: str, pull: dict,
            section: Optional[str], base: str) -> int:
    """Finish a land that stopped after GitHub merged `pull` into `base` at the local head."""
    rules = config["claim"]
    # The remote branch may already be gone; the claim commit is still in the local history,
    # and `claim_base` fetched the configured base.
    found = claims.claim_commit(root, f"{rules['remote']}/{rules['baseBranch']}", "HEAD", number)
    owner = found.session if found else None
    if owner != session:
        raise LandError(f"{branch} is claimed by session {owner or 'unknown: no claim commit'}, not {session}")
    # The merged body is what GitHub merged with; a different request cannot change it now.
    keyword, action = merge_intent(pull["number"], pull["body"], number)
    if section is not None and section != action:
        raise LandError(f"#{pull['number']} merged with `{keyword} #{number}` and "
                        + ("different validation text" if action else "no validation handoff")
                        + "; run land again without --needs-user-validation to finish what it merged")
    if action is not None:
        _scrub(root, config, "validation text", action)
    owner_name, name = _repository(gh)
    issue = start.load_issue(gh, owner_name, name, number, rules, config["project"]["title"])
    validate_existing_bug_body(pull["body"], issue["labels"], pull["number"])
    if issue["item"] is None:
        raise LandError(f"#{number} is not in the Project; add it back first")
    merge_sha = pull["mergeCommit"]["oid"]
    print(f"resumed:  #{pull['number']} merged {head[:12]} as {merge_sha}")
    after_merge(gh, root, config, issue, pull["number"], merge_sha, head, branch, action, resumable=True,
                base=base)
    print("cleanup:  run `work cleanup` from this worktree once you are done in it")
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
    found = {c.branch: c for c in claims.all_claims(repo, rules["remote"], rules["baseBranch"])}
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
            "session": found[node["headRefName"]].session if node["headRefName"] in found else None,
            # Where the claim lands, and where the pull request would merge; they must agree.
            "base": (found[node["headRefName"]].base if node["headRefName"] in found else None)
            or rules["baseBranch"],
            "pull_base": node["baseRefName"],
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
            print(f"#{row['issue']} PR #{row['pr']} {row['branch']} into {row['pull_base']} "
                  f"session {row['session'] or '?'} "
                  f"checks {row['checks']} verify {row['verify']} unresolved {row['unresolved']} head {age} "
                  f"{'worktree here' if row['worktree'] else 'no local worktree'}")
        print(f"{len(rows)} open pull request(s) from claim branches")
        return 0

    rules = config["claim"]
    remote = rules["remote"]
    root = Path(_out(repo, "rev-parse", "--show-toplevel"))
    matching = [row for row in rows if row["issue"] == number]
    if len(matching) != 1:
        raise LandError(f"expected one open pull request from a claim branch for #{number}, found {len(matching)}")
    row = matching[0]
    head, branch, base = row["head"], row["branch"], row["base"]
    if row["pull_base"] != base:
        raise LandError(f"#{row['pr']} merges into {row['pull_base']}, but {branch} lands into {base}")
    state, details = head_state(row["contexts"], config)
    if state != "success":
        raise LandError(f"#{row['pr']} is not ready at {head[:12]}: " + "; ".join(details))
    keyword, action = merge_intent(row["pr"], row["body"], number)
    if action is not None:
        # Checked before the merge, as land does, so a refusal cannot lose the handoff.
        _scrub(root, config, "validation text", action)
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
    validate_existing_bug_body(row["body"], issue["labels"], row["pr"])
    _refuse_stacked(gh, root, config, owner, name, branch)
    merge_sha = merge(gh, row["pr"], row["title"], number, head, keyword, base, time.sleep,
                      config["land"]["pollSeconds"])
    print(f"merged:   #{row['pr']} as {merge_sha}")
    after_merge(gh, root, config, issue, row["pr"], merge_sha, head, branch, action, resumable=False, base=base)
    return 0
