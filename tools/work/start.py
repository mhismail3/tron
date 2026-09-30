"""`work start`: claim one issue and create its worktree (README.md, `start`)."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

import claim as claims
from gh import Gh

_ISSUE = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      id number state title url
      labels(first: 50) { nodes { name } }
      blockedBy(first: 50) { nodes { number state } }
      comments(last: 100) { nodes { body } }
      projectItems(first: 20) {
        nodes {
          id
          project {
            id title
            field(name: "__FIELD__") {
              ... on ProjectV2SingleSelectField { id options { id name } }
            }
          }
          fieldValueByName(name: "__FIELD__") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}
"""

_STATUS_COUNT = """
query($project: ID!, $field: String!, $cursor: String) {
  node(id: $project) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { fieldValueByName(name: $field) { ... on ProjectV2ItemFieldSingleSelectValue { name } } }
      }
    }
  }
}
"""


def _git(cwd: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if completed.returncode != 0:
        raise claims.ClaimError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()


def primary_checkout(cwd: Path) -> Path:
    common = Path(_git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent


def _worktree_branch(repo: Path, path: Path) -> Optional[str]:
    """The branch checked out at a registered worktree path, '' if detached, None if unregistered."""
    current: Optional[Path] = None
    for line in _git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            current = Path(line[len("worktree "):]).resolve()
        elif current == path.resolve():
            if line.startswith("branch refs/heads/"):
                return line[len("branch refs/heads/"):]
            if line == "detached":
                return ""
    return None


def _session(explicit: Optional[str]) -> str:
    for value in (explicit, os.environ.get("WORK_SESSION_ID"), os.environ.get("PI_SESSION_ID")):
        if value and value.strip():
            return value.strip()
    raise claims.ClaimError("no session identity: pass --session or set WORK_SESSION_ID")


def _load_issue(gh: Gh, owner: str, name: str, number: int, rules: dict, project_title: str) -> dict:
    query = _ISSUE.replace("__FIELD__", rules["statusField"])
    raw = gh.graphql(query, owner=owner, name=name, number=number)["repository"]["issue"]
    if raw is None:
        raise claims.ClaimError(f"#{number} is not an issue in {owner}/{name}")
    items = [item for item in raw["projectItems"]["nodes"] if item["project"]["title"] == project_title]
    item = items[0] if items else None
    return {
        "id": raw["id"],
        "number": raw["number"],
        "state": raw["state"],
        "title": raw["title"],
        "url": raw["url"],
        "labels": [label["name"] for label in raw["labels"]["nodes"]],
        "open_blockers": [b["number"] for b in raw["blockedBy"]["nodes"] if b["state"] == "OPEN"],
        "comments": [c["body"] for c in raw["comments"]["nodes"]],
        "item": item,
        "status": (item["fieldValueByName"] or {}).get("name") if item else None,
    }


def _count_status(gh: Gh, project_id: str, field: str, status: str) -> int:
    count, cursor = 0, None
    while True:
        items = gh.graphql(_STATUS_COUNT, project=project_id, field=field, cursor=cursor)["node"]["items"]
        count += sum(1 for n in items["nodes"] if (n.get("fieldValueByName") or {}).get("name") == status)
        if not items["pageInfo"]["hasNextPage"]:
            return count
        cursor = items["pageInfo"]["endCursor"]


def _set_status(gh: Gh, item: dict, status: str) -> None:
    field = item["project"]["field"]
    option = next((o["id"] for o in field["options"] if o["name"] == status), None)
    if option is None:
        raise claims.ClaimError(f"Project field has no {status!r} option; run bootstrap")
    gh.graphql(
        "mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) { updateProjectV2ItemFieldValue("
        "input: {projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $option}}) "
        "{ projectV2Item { id } } }",
        project=item["project"]["id"], item=item["id"], field=field["id"], option=option,
    )


def run(gh: Gh, cwd: Path, config: dict, number: int, session_arg: Optional[str]) -> int:
    rules = config["claim"]
    remote, base = rules["remote"], rules["baseBranch"]
    session = _session(session_arg)
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    issue = _load_issue(gh, owner, name, number, rules, config["project"]["title"])

    existing = claims.existing_claims(cwd, remote, base, number)
    mine = [c for c in existing if c.session == session]
    others = [c for c in existing if c.session != session]
    if others and not mine:
        owners = ", ".join(f"{c.branch} (session {c.session or 'unknown: no claim commit'})" for c in others)
        raise claims.ClaimError(f"#{number} is already claimed: {owners}")

    primary = primary_checkout(cwd)
    root = (primary / rules["worktreeRoot"]).resolve()
    if mine:
        branch = mine[0].branch
        print(f"resuming the claim on {branch}")
        if issue["state"] != "OPEN":
            raise claims.ClaimError(f"#{number} is closed")
    else:
        reasons = claims.ineligibility(issue, rules)
        if reasons:
            raise claims.ClaimError(f"#{number} cannot be claimed: " + "; ".join(reasons))
        slug = claims.slugify(issue["title"])
        branch = claims.branch_name(claims.branch_type(issue["labels"], rules), number, slug)
    worktree = root / branch.split("/", 1)[1]
    at_path = _worktree_branch(cwd, worktree)
    if worktree.exists() and at_path != branch:
        raise claims.ClaimError(f"{worktree} exists and is not a worktree on {branch}; move it first")

    if not mine:
        result = claims.create_claim(cwd, remote, base, branch, number, session)
        if not result.won or not claims.resolve_race(cwd, remote, base, number, session):
            winner = claims.existing_claims(cwd, remote, base, number)
            raise claims.ClaimError(
                f"#{number} was claimed by another session first: "
                + ", ".join(f"{c.branch} (session {c.session})" for c in winner)
            )
        print(f"claimed #{number} as {branch} on {remote}")

    # The branch is the claim; Status and the comment project it. A failure
    # here leaves a valid claim, and re-running start completes them.
    item = issue["item"]
    if item is None:
        raise claims.ClaimError(f"#{number} left the Project; add it back and re-run start")
    if issue["status"] != rules["claimedStatus"]:
        _set_status(gh, item, rules["claimedStatus"])
    published = os.path.relpath(worktree, primary.parent)
    marker = f"<!-- work:claim session={session} branch={branch} -->"
    if not any(marker in body for body in issue["comments"]):
        base_sha = _git(cwd, "rev-parse", f"{remote}/{base}")
        gh.run("issue", "comment", str(number), "--body-file", "-",
               stdin=claims.claim_comment(session, branch, published, base_sha))

    if at_path != branch:
        _git(cwd, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}")
        root.mkdir(parents=True, exist_ok=True)
        local = subprocess.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"], cwd=cwd,
                               capture_output=True).returncode == 0
        if local:
            _git(cwd, "worktree", "add", str(worktree), branch)
        else:
            _git(cwd, "worktree", "add", "--track", "-b", branch, str(worktree), f"{remote}/{branch}")

    in_progress = _count_status(gh, item["project"]["id"], rules["statusField"], rules["claimedStatus"])
    if in_progress > rules["softCap"]:
        print(f"warning: {in_progress} items are {rules['claimedStatus']} (soft cap {rules['softCap']})",
              file=sys.stderr)
    print(f"issue:    {issue['url']}")
    print(f"branch:   {branch}")
    print(f"worktree: {worktree}")
    return 0
