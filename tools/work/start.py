"""`work start`: claim one issue and create its worktree (README.md, `start`)."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, Optional

import claim as claims
from comments import guard_public_text
import handoff
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

def _git(cwd: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if completed.returncode != 0:
        raise claims.ClaimError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()


def primary_checkout(cwd: Path) -> Path:
    common = Path(_git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent


def list_worktrees(repo: Path) -> Dict[Path, str]:
    """Every registered worktree's resolved path and its branch ('' when detached)."""
    worktrees: Dict[Path, str] = {}
    current: Optional[Path] = None
    for line in _git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            current = Path(line[len("worktree "):]).resolve()
            worktrees[current] = ""
        elif current is not None and line.startswith("branch refs/heads/"):
            worktrees[current] = line[len("branch refs/heads/"):]
    return worktrees


def _worktree_branch(repo: Path, path: Path) -> Optional[str]:
    """The branch checked out at a registered worktree path, '' if detached, None if unregistered."""
    return list_worktrees(repo).get(path.resolve())


def session_of(explicit: Optional[str]) -> str:
    for value in (explicit, os.environ.get("WORK_SESSION_ID"), os.environ.get("PI_SESSION_ID")):
        if value and value.strip():
            return value.strip()
    raise claims.ClaimError("no session identity: pass --session or set WORK_SESSION_ID")


def _take_over_settled_claim(gh: Gh, cwd: Path, config: dict, number: int, session: str, others: list) -> bool:
    """A Home task successor takes over the claim of a provably settled owner (#929).

    The Gateway's durable task state is the proof: the old owner's Home task is settled and
    this session runs a live Home task, so no maintainer `--force-maintainer` is needed.
    The transfer is the ordinary audited `handoff` (claim trailer and issue comment). Live,
    unknown and indeterminate owners still refuse, naming the verdict.
    """
    owners = ", ".join(f"{c.branch} (session {c.session or 'unknown: no claim commit'})" for c in others)
    if len(others) != 1 or not others[0].session:
        raise claims.ClaimError(f"#{number} is already claimed: {owners}")
    old = others[0].session
    state, why = handoff.owner_status(old)
    if state != "settled":
        raise claims.ClaimError(f"#{number} is already claimed: {owners}; owner is {state} ({why})")
    task, reason = handoff.home_task(session)
    if task is None:
        raise claims.ClaimError(f"#{number} is claimed by settled owner {old}; this session runs no live Home task ({reason}), "
                                f"so take it over with `scripts/tron work handoff {number} --reason TEXT`")
    handoff.run(gh, cwd, config, number, session, False, f"successor Home task {task} takes over from settled owner: {why}"[:500])
    return True


def load_issue(gh: Gh, owner: str, name: str, number: int, rules: dict, project_title: str) -> dict:
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


def set_status(gh: Gh, item: dict, status: str) -> None:
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


def run(gh: Gh, cwd: Path, config: dict, number: int, session_arg: Optional[str],
        integration: bool = False, requested_base: Optional[str] = None, requested_areas=None) -> int:
    areas = claims.normalized_areas(requested_areas or [])
    rules = config["claim"]
    remote, default_base = rules["remote"], rules["baseBranch"]
    base = requested_base or default_base
    base_sha = None
    if subprocess.run(["git", "check-ref-format", f"refs/heads/{base}"], capture_output=True).returncode:
        raise claims.ClaimError(f"invalid base branch: {base}")
    session = session_of(session_arg)
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    issue = load_issue(gh, owner, name, number, rules, config["project"]["title"])

    existing = claims.existing_claims(cwd, remote, default_base, number)
    mine = [c for c in existing if c.session == session]
    others = [c for c in existing if c.session != session]
    if others and not mine:
        if _take_over_settled_claim(gh, cwd, config, number, session, others):
            existing = claims.existing_claims(cwd, remote, default_base, number)
            mine = [c for c in existing if c.session == session]
        if not mine:
            raise claims.ClaimError(f"#{number} was handed off but its claim does not name {session}")

    primary = primary_checkout(cwd)
    root = (primary / rules["worktreeRoot"]).resolve()
    if mine:
        branch = mine[0].branch
        if areas and areas != mine[0].areas:
            raise claims.ClaimError("cannot change creation-time areas (possibly unknown/unreadable); omit --area to resume and report refined scope in its issue/check-in")
        areas = mine[0].areas
        if requested_base and mine[0].base and requested_base != mine[0].base:
            raise claims.ClaimError(f"#{number} is already claimed from {mine[0].base}; cannot resume it from {requested_base}")
        base = requested_base or mine[0].base or default_base
        base_sha = mine[0].base_sha
        print(f"resuming the claim on {branch} from {base}")
        if issue["state"] != "OPEN":
            raise claims.ClaimError(f"#{number} is closed")
    else:
        # Only the epic label is exempted by explicit integration creation;
        # all other exclusions, closed issues and blockers still refuse.
        eligible = {**issue, "labels": [label for label in issue["labels"] if label != "epic"]} if integration else issue
        reasons = claims.ineligibility(eligible, rules)
        if reasons:
            raise claims.ClaimError(f"#{number} cannot be claimed: " + "; ".join(reasons))
        slug = claims.slugify(issue["title"])
        branch = claims.branch_name("integration" if integration else claims.branch_type(issue["labels"], rules), number, slug)
    worktree = root / branch.split("/", 1)[1]
    at_path = _worktree_branch(cwd, worktree)
    if worktree.exists() and at_path != branch:
        raise claims.ClaimError(f"{worktree} exists and is not a worktree on {branch}; move it first")

    published = os.path.relpath(worktree, primary.parent)
    # Areas also enter the public claim commit: reject before pushing, not just before commenting.
    guard_public_text(cwd, config, claims.claim_comment(session, branch, published, base, base_sha or "pending", areas))
    if not mine:
        # A pre-existing local ref is not the new remote claim. Reusing it would
        # leave the worktree ownerless despite publishing canonical metadata.
        if subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=cwd).returncode == 0:
            raise claims.ClaimError(f"local branch {branch} already exists without this remote claim; refusing adoption")
        result = claims.create_claim(cwd, remote, base, branch, number, session, areas)
        if not result.won or not claims.resolve_race(cwd, remote, default_base, number, session):
            winner = claims.existing_claims(cwd, remote, default_base, number)
            raise claims.ClaimError(
                f"#{number} was claimed by another session first: "
                + ", ".join(f"{c.branch} (session {c.session})" for c in winner)
            )
        base_sha = result.base
        print(f"claimed #{number} as {branch} on {remote}")

    # The branch is the claim; Status and the comment project it. A failure
    # here leaves a valid claim, and re-running start completes them.
    item = issue["item"]
    if item is None:
        raise claims.ClaimError(f"#{number} left the Project; add it back and re-run start")
    if issue["status"] not in rules["claimedStatuses"]:
        set_status(gh, item, rules["claimedStatus"])
    marker = f"<!-- work:claim session={session} branch={branch} -->"
    if not any(marker in body for body in issue["comments"]):
        if base_sha is None:
            # Existing claims predate the creation-base receipt. Do not invent
            # historical provenance: label the observation as current instead.
            _git(cwd, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{base}:refs/remotes/{remote}/{base}")
            base_sha = _git(cwd, "rev-parse", f"{remote}/{base}")
            base = f"{base} (current; creation base unrecorded)"
        comment = claims.claim_comment(session, branch, published, base, base_sha, areas)
        guard_public_text(cwd, config, comment)
        gh.run("issue", "comment", str(number), "--body-file", "-", stdin=comment)

    if at_path != branch:
        _git(cwd, "fetch", "-q", "--no-tags", remote, f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}")
        root.mkdir(parents=True, exist_ok=True)
        local = subprocess.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"], cwd=cwd,
                               capture_output=True).returncode == 0
        if local:
            _git(cwd, "worktree", "add", str(worktree), branch)
        else:
            _git(cwd, "worktree", "add", "--track", "-b", branch, str(worktree), f"{remote}/{branch}")

    # Warm only independently-owned dependency installs; iOS products belong to
    # scripts/tron-ios-test and are seeded only when that runner starts a build.

    print(f"issue:    {issue['url']}")
    print(f"branch:   {branch}")
    print(f"worktree: {worktree}")
    try:
        print(claims.render_advice(claims.area_advice(areas, claims.all_claims(cwd, remote, default_base), branch)))
    except claims.ClaimError as error:
        # The claim already exists: loss of advisory data must not undo admission.
        print(f"overlap advisory unavailable: {error}", file=sys.stderr)
    return 0
