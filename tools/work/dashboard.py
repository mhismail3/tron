"""`work dashboard`: one read-only view of all work, fetched live (README.md, `dashboard`).

`fetch_github` and the Git reads in `run` collect a snapshot; `build` turns
it into the model that `render_html`, `render_text` and `--json` present.
"""
from __future__ import annotations

import html
import json
import os
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePath
from typing import Callable, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlencode, quote

import claim as claims
import start
from gh import Gh, GhError

# Workflow rule: a claim with no push or comment for this long is flagged.
STALE_AFTER = timedelta(hours=48)
_HEX = re.compile(r"[0-9a-fA-F]{6}")


class DashboardError(RuntimeError):
    pass


# ------------------------------------------------------------------ GitHub

_ISSUE_FIELDS = """
  number title url state closedAt
  repository { nameWithOwner }
  labels(first: 30) { nodes { name } }
  parent { number }
  subIssuesSummary { total completed }
  blockedBy(first: 20) { nodes { number state } }
  comments(last: 1) { nodes { createdAt } }
"""

_PROJECT = """
query($owner: String!, $name: String!, $title: String!) {
  repository(owner: $owner, name: $name) {
    projectsV2(first: 20, query: $title) { nodes { id title } }
  }
}
"""

_ITEMS = """
query($project: ID!, $cursor: String, $status: String!, $priority: String!, $rank: String!) {
  node(id: $project) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id type
          status: fieldValueByName(name: $status) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          priority: fieldValueByName(name: $priority) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          rank: fieldValueByName(name: $rank) { ... on ProjectV2ItemFieldNumberValue { number } }
          content { __typename ... on Issue { __ISSUE__ } }
        }
      }
    }
  }
}
""".replace("__ISSUE__", _ISSUE_FIELDS)

_LABELED = """
query($owner: String!, $name: String!, $labels: [String!], $cursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, labels: $labels, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes { __typename __ISSUE__ }
    }
  }
}
""".replace("__ISSUE__", _ISSUE_FIELDS)

_PULLS = """
query($owner: String!, $name: String!, $verify: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url isDraft headRefName isCrossRepository
        comments(last: 1) { nodes { createdAt } }
        commits(last: 1) {
          nodes { commit { oid statusCheckRollup { state } status { context(name: $verify) { state } } } }
        }
      }
    }
  }
}
"""


def _pages(fetch: Callable[[Optional[str]], dict]) -> List[dict]:
    nodes: List[dict] = []
    cursor = None
    while True:
        page = fetch(cursor)
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return nodes
        cursor = page["pageInfo"]["endCursor"]


def _issue_states(gh: Gh, owner: str, name: str, numbers: List[int]) -> Dict[int, str]:
    """OPEN, CLOSED, PULL_REQUEST or MISSING for each number, 100 aliases per query."""
    states: Dict[int, str] = {}
    for start_at in range(0, len(numbers), 100):
        chunk = numbers[start_at:start_at + 100]
        fields = " ".join(
            f"n{n}: issueOrPullRequest(number: {int(n)}) {{ __typename ... on Issue {{ state }} }}" for n in chunk
        )
        query = f"query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}"
        repository = gh.graphql(query, missing_ok=True, owner=owner, name=name)["repository"]
        for n in chunk:
            node = repository.get(f"n{n}")
            if node is None:
                states[n] = "MISSING"
            elif node["__typename"] != "Issue":
                states[n] = "PULL_REQUEST"
            else:
                states[n] = node["state"]
    return states


def _ci_evidence(gh: Gh, repository: str, config: dict, pulls: List[dict]) -> List[dict]:
    """Read current Actions evidence, never persist a second failure registry.

    Main push evidence survives a PR's merge. PR evidence is pinned to the exact
    open head, not merely its reusable branch name. API failures are not green.
    """
    board = config["dashboard"]
    workflow = board.get("ciWorkflow")
    names = board.get("advisoryJobs", [])
    if not workflow or not names:
        return []
    targets = [(config["claim"]["baseBranch"], "push", None, "main")]
    for pull in pulls:
        if pull.get("isCrossRepository"):
            continue
        commits = pull["commits"]["nodes"]
        sha = commits[-1]["commit"]["oid"] if commits else None
        targets.append((pull["headRefName"], "pull_request", sha, f"PR #{pull['number']}"))
    rows = []
    runs_cache: dict = {}
    jobs_cache: dict = {}
    for branch, event, sha, scope in targets:
        row = {"scope": scope, "branch": branch, "sha": sha, "url": None,
               "state": "missing", "jobs": {}}
        try:
            # A PR without a known head must not fall back to branch evidence.
            if event == "pull_request" and not sha:
                rows.append(row)
                continue
            query = {"branch": branch, "event": event, "per_page": 1}
            if sha:
                query["head_sha"] = sha
            path = f"repos/{repository}/actions/workflows/{quote(workflow, safe='')}/runs?{urlencode(query)}"
            if path not in runs_cache:
                runs_cache[path] = gh.rest("GET", path)["workflow_runs"]
            candidates = runs_cache[path]
            candidate = candidates[0] if candidates else None
            if candidate and (candidate["head_branch"] != branch or candidate["event"] != event
                              or candidate["head_repository"]["full_name"] != repository
                              or (sha and candidate["head_sha"] != sha)):
                candidate = None
            if candidate:
                row.update(sha=candidate["head_sha"], url=candidate["html_url"],
                           state=candidate["conclusion"] if candidate["status"] == "completed" else "pending")
                run_id = int(candidate["id"])
                if run_id not in jobs_cache:
                    jobs = []
                    # Job lists are paginated, bounded to 1,000. Incomplete
                    # evidence is unavailable, never a silently healthy subset.
                    for page in range(1, 11):
                        response = gh.rest("GET", f"repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
                        jobs.extend(response["jobs"])
                        if len(jobs) >= response["total_count"]:
                            break
                    else:
                        raise DashboardError("Actions job list exceeds 1,000 jobs")
                    jobs_cache[run_id] = jobs
                by_name = {job["name"]: job for job in jobs_cache[run_id]}
                for name in names:
                    job = by_name.get(name)
                    state = (job["conclusion"] or "unknown") if job and job["status"] == "completed" else "pending"
                    if not job:
                        state = "pending" if row["state"] == "pending" else "missing"
                    row["jobs"][name] = {"state": state, "url": job["html_url"] if job else None}
        except (GhError, DashboardError, KeyError, TypeError, ValueError):
            # Do not expose raw CLI diagnostics (which may hold local paths).
            row["state"] = "unavailable"
            row["jobs"] = {}
        rows.append(row)
    return rows


def fetch_github(gh: Gh, owner: str, name: str, config: dict, claim_numbers: Iterable[int]) -> dict:
    """GitHub's side of the snapshot; claim_numbers are the issues named by every claim-style branch."""
    board, rules = config["dashboard"], config["claim"]
    repository = f"{owner}/{name}"
    title = config["project"]["title"]
    linked = gh.graphql(_PROJECT, owner=owner, name=name, title=title)["repository"]["projectsV2"]["nodes"]
    projects = [p for p in linked if p["title"] == title]
    if len(projects) != 1:
        raise DashboardError(f"expected one Project titled {title!r} linked to {repository}, found {len(projects)}")
    project = projects[0]["id"]

    items = _pages(lambda cursor: gh.graphql(
        _ITEMS, project=project, cursor=cursor, status=rules["statusField"],
        priority=board["priorityField"], rank=board["rankField"],
    )["node"]["items"])
    labels = board["needsYouLabels"] + [board["regressionLabel"]]
    labeled = _pages(lambda cursor: gh.graphql(
        _LABELED, owner=owner, name=name, labels=labels, cursor=cursor,
    )["repository"]["issues"])
    pulls = _pages(lambda cursor: gh.graphql(
        _PULLS, owner=owner, name=name, verify=board["verifyContext"], cursor=cursor,
    )["repository"]["pullRequests"])

    known = {i["number"] for i in labeled}
    known |= {
        node["content"]["number"] for node in items
        if _repository_issue(node.get("content"), repository)
    }
    unknown = sorted(set(claim_numbers) - known)
    return {
        "repository": repository,
        "project_items": items,
        "labeled_issues": labeled,
        "pull_requests": pulls,
        "ci": _ci_evidence(gh, repository, config, pulls),
        "issue_states": _issue_states(gh, owner, name, unknown) if unknown else {},
    }


def _repository_issue(content: Optional[dict], repository: str) -> bool:
    # A deleted issue leaves its Project item with null content; drafts, pull
    # requests and other repositories' issues are not this dashboard's work.
    return bool(content) and content.get("__typename") == "Issue" \
        and content["repository"]["nameWithOwner"] == repository


# ------------------------------------------------------------------- model


def _time(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _last_comment(node: dict) -> Optional[datetime]:
    comments = (node.get("comments") or {}).get("nodes") or []
    return _time(comments[-1]["createdAt"]) if comments else None


def _issue(content: dict, status: Optional[str], priority: Optional[str], rank: Optional[float]) -> dict:
    return {
        "number": content["number"],
        "title": content["title"],
        "url": content["url"],
        "state": content["state"],
        "labels": [label["name"] for label in content["labels"]["nodes"]],
        "parent": (content.get("parent") or {}).get("number"),
        "sub_issues": content["subIssuesSummary"],
        "open_blockers": sorted(b["number"] for b in content["blockedBy"]["nodes"] if b["state"] == "OPEN"),
        "last_comment": _last_comment(content),
        "closed_at": _time(content.get("closedAt")),
        "status": status,
        "priority": priority,
        "rank": rank,
    }


def _ref(issue: dict) -> dict:
    return {key: issue[key] for key in ("number", "title", "url", "status", "priority", "labels")}


def _pull(node: dict) -> dict:
    commits = node["commits"]["nodes"]
    commit = commits[-1]["commit"] if commits else {}
    verify = ((commit.get("status") or {}).get("context") or {}).get("state")
    return {
        "number": node["number"],
        "title": node["title"],
        "url": node["url"],
        "draft": node["isDraft"],
        "checks": (commit.get("statusCheckRollup") or {}).get("state"),
        "verify": verify,
        "last_comment": _last_comment(node),
    }


def _stamp(moment: Optional[datetime]) -> Optional[str]:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if moment else None


def build(snapshot: dict, config: dict, now: datetime) -> dict:
    rules, board = config["claim"], config["dashboard"]
    repository = snapshot["repository"]
    field = next(f for f in config["project"]["fields"] if f["name"] == board["priorityField"])
    priority_order = [option["name"] for option in field["options"]]

    def priority_index(issue: dict) -> int:
        name = issue["priority"]
        return priority_order.index(name) if name in priority_order else len(priority_order)

    issues: Dict[int, dict] = {}
    ignored = 0
    for node in snapshot["project_items"]:
        content = node.get("content")
        if not _repository_issue(content, repository):
            ignored += 1
            continue
        issues[content["number"]] = _issue(
            content,
            (node.get("status") or {}).get("name"),
            (node.get("priority") or {}).get("name"),
            (node.get("rank") or {}).get("number"),
        )
    for content in snapshot["labeled_issues"]:
        if content["number"] not in issues and _repository_issue(content, repository):
            issues[content["number"]] = _issue(content, None, None, None)

    def state_of(number: int) -> str:
        if number in issues:
            return issues[number]["state"]
        return snapshot["issue_states"].get(number, "MISSING")

    claims_by_issue: Dict[int, List[dict]] = {}
    for entry in sorted(snapshot["claims"], key=lambda c: c["branch"]):
        claims_by_issue.setdefault(claims.claimed_issue(entry["branch"]), []).append(entry)
    live_branches = {c["branch"] for n, cs in claims_by_issue.items() if state_of(n) == "OPEN" for c in cs}

    # Worktrees: only those under the worktree root are reported, and only
    # relative to the checkout's parent directory (the repository may be public).
    root = PurePath(snapshot["worktree_root"])
    worktree_of: Dict[str, str] = {}
    orphan_worktrees: List[dict] = []
    for tree in snapshot["worktrees"]:
        path = PurePath(tree["path"])
        if not path.is_relative_to(root) or path == root:
            continue
        relative = os.path.relpath(path, snapshot["checkout_parent"])
        branch = tree["branch"] or None
        if branch in live_branches:
            worktree_of[branch] = relative
            continue
        number = claims.claimed_issue(branch) if branch else None
        if branch is None:
            reason = "detached HEAD"
        elif number is None:
            reason = "not a claim branch"
        elif state_of(number) == "OPEN":
            reason = f"no remote claim branch for #{number}" + _CLEANUP_HINT
        elif state_of(number) == "CLOSED":
            reason = _absence(number, "CLOSED") + _CLEANUP_HINT
        else:
            reason = _absence(number, state_of(number))
        orphan_worktrees.append({"path": relative, "branch": branch, "reason": reason})

    orphan_branches = [
        {"branch": c["branch"], "session": c["session"], "reason": _absence(n, state_of(n))}
        for n, cs in sorted(claims_by_issue.items()) if state_of(n) != "OPEN" for c in cs
    ]

    pulls = {}
    for node in sorted(snapshot["pull_requests"], key=lambda p: -p["number"]):
        # Claim branch names are public; a fork can open a PR with the same head name.
        if not node["isCrossRepository"]:
            pulls[node["headRefName"]] = _pull(node)  # the oldest PR for a head wins

    open_issues = sorted((i for i in issues.values() if i["state"] == "OPEN"), key=lambda i: i["number"])
    excluded = set(rules["excludeLabels"])

    def claimable(issue: dict) -> bool:
        return not excluded & set(issue["labels"])

    needs_you = []
    for issue in open_issues:
        reasons = sorted(set(issue["labels"]) & set(board["needsYouLabels"]))
        if issue["status"] == board["needsYouStatus"]:
            reasons.append(f"Status {issue['status']}")
        if reasons:
            needs_you.append({**_ref(issue), "reasons": reasons})
    needs_you.sort(key=lambda e: (priority_index(issues[e["number"]]), e["number"]))

    epics = [
        {**_ref(i), "rank": i["rank"], "completed": i["sub_issues"]["completed"], "total": i["sub_issues"]["total"]}
        for i in open_issues if board["epicLabel"] in i["labels"]
    ]
    epics.sort(key=lambda e: (e["rank"] is None, e["rank"] or 0, e["number"]))

    in_progress = []
    for issue in open_issues:
        if not claims.is_active(issue["state"], issue["labels"], issue["status"], rules):
            continue
        owned = claims_by_issue.get(issue["number"], [])
        winner = owned[0] if owned else None  # smallest ref name wins (claim.resolve_race)
        pull = pulls.get(winner["branch"]) if winner else None
        moments = [issue["last_comment"], _time(winner["committed_at"]) if winner else None,
                   pull["last_comment"] if pull else None]
        latest = max((m for m in moments if m is not None), default=None)
        idle = (now - latest) if latest else None
        in_progress.append({
            **_ref(issue),
            "branch": winner["branch"] if winner else None,
            "session": winner["session"] if winner else None,
            "worktree": worktree_of.get(winner["branch"]) if winner else None,
            "last_activity": _stamp(latest),
            "idle_hours": round(idle.total_seconds() / 3600, 1) if idle is not None else None,
            "stale": idle is None or idle > STALE_AFTER,
            "pr": {k: v for k, v in pull.items() if k != "last_comment"} if pull else None,
        })

    def effective_rank(issue: dict) -> Optional[float]:
        parent = issues.get(issue["parent"]) if issue["parent"] else None
        if parent is not None and parent["rank"] is not None:
            return parent["rank"]
        return issue["rank"]

    ready = [
        {**_ref(i), "rank": effective_rank(i), "epic": i["parent"], "open_blockers": i["open_blockers"]}
        for i in open_issues if i["status"] == rules["readyStatus"] and claimable(i)
    ]
    ready.sort(key=lambda e: (e["rank"] is None, e["rank"] or 0, priority_index(issues[e["number"]]),
                              bool(e["open_blockers"]), e["number"]))

    blocked = [{**_ref(i), "open_blockers": i["open_blockers"]}
               for i in open_issues if i["status"] == board["blockedStatus"]]

    disagreements = []
    for number, owned in sorted(claims_by_issue.items()):
        if state_of(number) != "OPEN":
            continue  # reported as orphan branches
        issue = issues.get(number)
        status = issue["status"] if issue else None
        base = _ref(issue) if issue else {"number": number, "title": None, "url": None}
        if status not in rules["claimedStatuses"]:
            disagreements.append({**base, "kind": "claim-without-claimed-status",
                                  "detail": f"claim branch {owned[0]['branch']}; Status is "
                                            + (status or "unset or not in the Project")})
        if len(owned) > 1:
            disagreements.append({**base, "kind": "multiple-claims",
                                  "detail": "claim branches " + ", ".join(c["branch"] for c in owned)})
    # Needs you is not active: merged work awaiting validation has no branch.
    for row in in_progress:
        if row["branch"] is None:
            disagreements.append({**{k: row[k] for k in ("number", "title", "url")},
                                  "kind": "active-without-claim",
                                  "detail": f"Status is {row['status']} but no claim branch exists"})
    disagreements.sort(key=lambda d: (d["number"], d["kind"]))

    vocabulary = _vocabulary(config)
    work = _work(issues, vocabulary, config, ready, now)
    classification = _classification(open_issues, vocabulary, config)

    return {
        "generated_at": _stamp(now),
        "repository": repository,
        "project": config["project"]["title"],
        "needs_you": needs_you,
        "epics": epics,
        "in_progress": in_progress,
        "ready": ready,
        "blocked": blocked,
        "stale": [row for row in in_progress if row["stale"]],
        "soft_cap": {"in_progress": len(in_progress), "cap": rules["softCap"],
                     "over": len(in_progress) > rules["softCap"]},
        "disagreements": disagreements,
        "orphans": {"worktrees": orphan_worktrees, "branches": orphan_branches},
        "regressions": [_ref(i) for i in open_issues if board["regressionLabel"] in i["labels"]],
        "classification": classification,
        "ci": snapshot.get("ci", []),
        "work": work,
        "priority_order": priority_order,
        "recent_days": board["recentDays"],
        "vocabulary": vocabulary,
        "ignored_items": ignored,
    }


def _slug(value: str) -> str:
    return "-".join("".join(c if c.isalnum() else " " for c in value.lower()).split())


def _vocabulary(config: dict) -> dict:
    """Filter tokens, from declared labels and Status options only (failure mode 46)."""
    board = config["dashboard"]
    declared = config.get("labels", [])

    def group(prefix: str) -> List[dict]:
        return [{"label": label["name"], "token": _slug(label["name"][len(prefix):]),
                 "color": label["color"] if _HEX.fullmatch(label.get("color", "")) else None,
                 "description": label.get("description", "")}
                for label in declared if label["name"].startswith(prefix)]

    status_field = next(f for f in config["project"]["fields"] if f["name"] == config["claim"]["statusField"])
    return {
        "kinds": group(board["kindPrefix"]),
        "visibilities": group(board["visibilityPrefix"]),
        "areas": group(board["areaPrefix"]),
        "statuses": [{"label": o["name"], "token": _slug(o["name"])} for o in status_field["options"]],
    }


def _status_order(config: dict) -> List[str]:
    rules, board = config["claim"], config["dashboard"]
    first = [board["needsYouStatus"], *rules["activeStatuses"], rules["readyStatus"], board["blockedStatus"]]
    status_field = next(f for f in config["project"]["fields"] if f["name"] == rules["statusField"])
    rest = [o["name"] for o in status_field["options"] if o["name"] not in first]
    return first + rest


def _work(issues: Dict[int, dict], vocabulary: dict, config: dict, ready: List[dict], now: datetime) -> List[dict]:
    """Every open non-epic issue once, plus those closed in the last recentDays (failure mode 45)."""
    board = config["dashboard"]
    since = now - timedelta(days=board["recentDays"])
    queue = {entry["number"]: position for position, entry in enumerate(ready, 1)}
    order = _status_order(config)
    statuses = {s["label"]: s["token"] for s in vocabulary["statuses"]}

    def single(labels: List[str], group: List[dict]) -> Optional[str]:
        found = [g["token"] for g in group if g["label"] in labels]
        return found[0] if len(found) == 1 else None

    rows = []
    for issue in issues.values():
        if board["epicLabel"] in issue["labels"]:
            continue
        closed = issue["state"] != "OPEN"
        if closed and not (issue["closed_at"] and issue["closed_at"] >= since):
            continue
        rows.append({
            **_ref(issue),
            "state": issue["state"],
            "status_token": "closed" if closed else statuses.get(issue["status"] or "", ""),
            "kind": single(issue["labels"], vocabulary["kinds"]),
            "visibility": single(issue["labels"], vocabulary["visibilities"]),
            "areas": [g["token"] for g in vocabulary["areas"] if g["label"] in issue["labels"]],
            "epic": issue["parent"],
            "open_blockers": issue["open_blockers"],
            "queue": queue.get(issue["number"]),
            "closed_at": _stamp(issue["closed_at"]) if closed else None,
        })

    def key(row: dict):
        if row["state"] != "OPEN":
            return (len(order) + 1, -(_time(row["closed_at"]) or now).timestamp(), row["number"])
        rank = order.index(row["status"]) if row["status"] in order else len(order)
        return (rank, row["queue"] or 0, row["number"])

    return sorted(rows, key=key)


def _classification(open_issues: List[dict], vocabulary: dict, config: dict) -> List[dict]:
    """Missing, repeated or undeclared kind/visibility labels, and committed ideas (failure mode 44)."""
    board, rules = config["dashboard"], config["claim"]
    committed = {rules["readyStatus"], *rules["claimedStatuses"]}
    problems = []
    for issue in open_issues:
        if board["epicLabel"] in issue["labels"]:
            continue
        found = []
        for prefix, group, noun in ((board["kindPrefix"], vocabulary["kinds"], "kind"),
                                    (board["visibilityPrefix"], vocabulary["visibilities"], "visibility")):
            declared = {g["label"] for g in group}
            present = [label for label in issue["labels"] if label.startswith(prefix)]
            undeclared = [label for label in present if label not in declared]
            if undeclared:
                found.append("undeclared " + ", ".join(undeclared))
            if not present:
                found.append(f"no {noun} label")
            elif len(present) > 1:
                found.append(f"{len(present)} {noun} labels: " + ", ".join(present))
        if board["ideaLabel"] in issue["labels"] and issue["status"] in committed:
            found.append(f"{board['ideaLabel']} while {issue['status']}")
        if found:
            problems.append({**_ref(issue), "problem": "; ".join(found)})
    return problems


# A claim branch's worktree whose pull request merged at its head is provably done (README.md, `cleanup`).
_CLEANUP_HINT = "; work cleanup --all removes it once its pull request merged at this head"


def _absence(number: int, state: str) -> str:
    return {
        "CLOSED": f"issue #{number} is closed",
        "PULL_REQUEST": f"#{number} is a pull request, not an issue",
    }.get(state, f"issue #{number} does not exist")


# ---------------------------------------------------------------- rendering


def _ci_alert(row: dict) -> bool:
    return row["state"] not in {"success", "skipped"} or any(
        job["state"] not in {"success", "skipped"} for job in row["jobs"].values())


def _ci_text(row: dict) -> str:
    jobs = ", ".join(f"{name}={job['state']}" for name, job in row["jobs"].items())
    return (f"{row['scope']} {row['branch']} {(row['sha'] or 'unknown')[:12]}: {row['state']}"
            + (f" ({jobs})" if jobs else "") + (f" {row['url']}" if row["url"] else ""))


def render_text(model: dict) -> str:
    cap = model["soft_cap"]
    lines = [f"{model['repository']} - Project {model['project']!r} - {model['generated_at']}"]

    def section(title: str, rows: List[str]) -> None:
        lines.append(f"{title} ({len(rows)})")
        lines.extend("  " + row for row in rows)

    section("Needs you", [f"#{e['number']} {e['title']} [{', '.join(e['reasons'])}]" for e in model["needs_you"]])
    section("Epics", [f"#{e['number']} {e['title']} {e['completed']}/{e['total']}" for e in model["epics"]])
    section(f"In progress, soft cap {cap['cap']}" + (" EXCEEDED" if cap["over"] else ""), [
        f"#{r['number']} {r['status']} {r['branch'] or '(no claim branch)'} session {r['session'] or '?'} "
        f"{_idle(r['idle_hours'])}" + (f" PR #{r['pr']['number']} checks {r['pr']['checks'] or '-'} "
                                        f"verify {r['pr']['verify'] or '-'}" if r["pr"] else "")
        + (" STALE" if r["stale"] else "")
        for r in model["in_progress"]
    ])
    section("Ready", [f"#{e['number']} {e['title']}" + (f" (waits on {_numbers(e['open_blockers'])})"
                                                        if e["open_blockers"] else "") for e in model["ready"]])
    section("Blocked", [f"#{e['number']} {e['title']}" for e in model["blocked"]])
    section("Stale claims", [f"#{r['number']} {r['branch']} {_idle(r['idle_hours'])}" for r in model["stale"]])
    section("Disagreements", [f"#{d['number']} {d['kind']}: {d['detail']}" for d in model["disagreements"]])
    orphans = model["orphans"]
    section("Orphans", [f"worktree {o['path']}: {o['reason']}" for o in orphans["worktrees"]]
            + [f"branch {o['branch']}: {o['reason']}" for o in orphans["branches"]])
    section("Regressions", [f"#{e['number']} {e['title']}" for e in model["regressions"]])
    section("Advisory CI (latest main push and exact open PR heads)", [_ci_text(row) for row in model["ci"]])
    section("Classification", [f"#{p['number']} {p['problem']}" for p in model["classification"]])
    if model["ignored_items"]:
        lines.append(f"Ignored {model['ignored_items']} Project item(s) without an issue of this repository")
    return "\n".join(lines) + "\n"


def _numbers(numbers: List[int]) -> str:
    return ", ".join(f"#{n}" for n in numbers)


_CSS = """
:root{color-scheme:light dark;--bg:#f2eee4;--panel:#fbf8f1;--ink:#1c1a16;--muted:#6d675b;--rule:#d9d1c0;
--accent:#d4500f;--hot:#c0392b;--warm:#b7791f;--good:#2e7d4f;--cool:#1b7c83;--chip:#ebe5d7;
--mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,monospace;
--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#12110e;--panel:#1b1a16;--ink:#ede6d5;--muted:#9c9586;
--rule:#353129;--accent:#ff8a3d;--hot:#ff6b5b;--warm:#f2b84b;--good:#7bd389;--cool:#5cc6c9;--chip:#26241f}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0 auto;max-width:980px;padding:16px 14px 48px;background:var(--bg);color:var(--ink);
font:15px/1.45 var(--sans);overflow-wrap:anywhere}
a{color:inherit;text-decoration:none}
a:hover,a:focus-visible{color:var(--accent)}
.mono,code,.num,.k,h2,.tile b,.chip,.tag{font-family:var(--mono)}
header{padding:6px 2px 14px}
.brand{font:700 12px/1 var(--mono);letter-spacing:.22em;text-transform:uppercase;color:var(--accent)}
h1{font:700 24px/1.15 var(--mono);letter-spacing:-.01em;margin:8px 0 4px}
.sub{color:var(--muted);font-size:13px}
.stripe{height:5px;margin-top:12px;border-radius:3px;background:linear-gradient(90deg,var(--hot) 0 25%,
var(--accent) 25% 50%,var(--warm) 50% 75%,var(--cool) 75%)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(96px,1fr));gap:8px;margin:4px 0 6px}
.tile{display:block;background:var(--panel);border:1px solid var(--rule);border-radius:10px;padding:10px 11px 9px}
.tile b{display:block;font-size:26px;line-height:1.05;font-weight:700}
.tile span{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.tile.hot{border-color:var(--hot);box-shadow:3px 3px 0 var(--hot)}.tile.hot b{color:var(--hot)}
section{margin-top:26px}
h2{display:flex;align-items:center;gap:10px;font-size:12px;font-weight:700;letter-spacing:.16em;
text-transform:uppercase;margin:0 0 10px;color:var(--ink)}
h2::after{content:"";flex:1;height:1px;background:var(--rule)}
h2 .count{font-weight:600;letter-spacing:0;color:var(--muted)}
.panel{background:var(--panel);border:1px solid var(--rule);border-radius:12px;overflow:hidden}
ul,ol{list-style:none;margin:0;padding:0}
.rows>li{border-top:1px solid var(--rule)}.rows>li:first-child{border-top:0}
.line{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 8px;padding:10px 12px}
.line .t{flex:1 1 220px;min-width:0}
.num{font-size:13px;font-weight:700;color:var(--accent)}
.tags{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
.tag{font-size:11px;line-height:18px;padding:0 6px;border-radius:5px;background:var(--chip);color:var(--muted);
max-width:100%}
.tag.p0{background:var(--hot);color:#fff}.tag.p1{background:var(--warm);color:#1c1a16}
.tag.bad{background:var(--hot);color:#fff}.tag.warn{background:var(--warm);color:#1c1a16}
.tag.ok{color:var(--good)}
.k{display:inline-block;width:9px;height:9px;border-radius:2px;background:var(--k,var(--muted));
flex:none;transform:translateY(-1px)}
details>summary{list-style:none;cursor:pointer}
details>summary::-webkit-details-marker{display:none}
details>summary .line::after{content:"+";font:700 14px var(--mono);color:var(--muted);margin-left:auto}
details[open]>summary .line::after{content:"\\2212"}
.more{padding:0 12px 12px 29px;color:var(--muted);font-size:13px;display:grid;gap:3px}
.more a{color:var(--accent)}
.more .key{font-weight:600;color:var(--ink)}
.alert{border-left:4px solid var(--hot)}
.flag{border-left:4px solid var(--warm)}
.group{padding:8px 12px 2px;font:700 11px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}
.clear{color:var(--good);font:13px var(--mono);padding:10px 12px}
.matrix{width:100%;border-collapse:collapse;font:13px var(--mono);overflow-wrap:normal}
.matrix th,.matrix td{padding:7px 8px;text-align:right;border-top:1px solid var(--rule);white-space:nowrap}
.matrix tr:first-child th{border-top:0;color:var(--muted);font-weight:600;font-size:11px;letter-spacing:.06em}
.matrix th:first-child{text-align:left}
.matrix td.z{color:var(--rule)}
.matrix tr.total td,.matrix tr.total th{font-weight:700}
.matrix label{cursor:pointer;display:inline-flex;gap:7px;align-items:center}
.filters{display:grid;gap:6px;margin:10px 0}
.frow{display:flex;gap:6px;align-items:center;overflow-x:auto;scrollbar-width:none;padding:1px 24px 1px 0;
-webkit-mask-image:linear-gradient(90deg,#000 calc(100% - 28px),transparent);mask-image:linear-gradient(90deg,#000 calc(100% - 28px),transparent)}
.frow::-webkit-scrollbar{display:none}
.flabel{flex:none;width:70px;font:700 10px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--muted)}
.chip{position:relative;flex:none;display:inline-flex;gap:6px;align-items:center;font-size:12px;line-height:28px;
padding:0 10px;border:1px solid var(--rule);border-radius:15px;background:var(--panel);cursor:pointer;
user-select:none;-webkit-user-select:none}
.chip input{position:absolute;opacity:0;width:1px;height:1px;margin:0}
.chip small{color:var(--muted);font-size:11px}
.chip:has(input:checked){background:var(--ink);color:var(--bg);border-color:var(--ink)}
.chip:has(input:checked) small{color:inherit;opacity:.7}
.chip:has(input:focus-visible){outline:2px solid var(--accent);outline-offset:2px}
.bar{height:6px;background:var(--chip);border-radius:3px;overflow:hidden;flex:1 1 80px;max-width:160px;align-self:center}
.bar span{display:block;height:100%;background:var(--good)}
.empty{color:var(--muted);font-size:13px;padding:10px 12px}
footer{margin-top:28px;color:var(--muted);font-size:12px}
@media (max-width:520px){h1{font-size:20px}.tile b{font-size:22px}.flabel{width:58px}
.line .t{flex-basis:100%}}
"""


def _e(value: object) -> str:
    return html.escape(str(value), quote=True)


def _link(url: Optional[str], text: str, css: str = "") -> str:
    # Only GitHub's own https URLs become links; anything else is plain text.
    cls = f' class="{css}"' if css else ""
    if url and url.startswith("https://"):
        return f'<a{cls} href="{_e(url)}">{_e(text)}</a>'
    return f"<span{cls}>{_e(text)}</span>"


def _num(entry: dict) -> str:
    return _link(entry.get("url"), f"#{entry['number']}", "num")


def _title(entry: dict) -> str:
    title = entry.get("title")
    return f'<span class="t">{_e(title)}</span>' if title else '<span class="t sub">not in the Project</span>'


def _tag(text: str, css: str = "") -> str:
    return f'<span class="tag {_e(css)}">{_e(text)}</span>' if text else ""


def _tags(*parts: str) -> str:
    kept = "".join(p for p in parts if p)
    return f'<span class="tags">{kept}</span>' if kept else ""


def _line(entry: Optional[dict], *parts: str, head: str = "") -> str:
    return f'<div class="line">{head or (_num(entry) + _title(entry))}{_tags(*parts)}</div>'


def _section(anchor: str, title: str, body: str, count: str = "") -> str:
    extra = f'<span class="count">{_e(count)}</span>' if count else ""
    return f'<section id="{anchor}"><h2>{_e(title)}{extra}</h2>{body}</section>'


def _rows(items: List[str], empty: str = "None") -> str:
    if not items:
        return f'<div class="panel"><p class="empty">{_e(empty)}</p></div>'
    return '<ul class="panel rows">' + "".join(items) + "</ul>"


def _idle(hours: Optional[float]) -> str:
    if hours is None:
        return "no activity"
    if hours < 1:
        return f"{int(hours * 60)}m ago"
    if hours < 48:
        return f"{int(hours)}h ago"
    return f"{int(hours // 24)}d ago"


def _check(label: str, state: Optional[str]) -> str:
    css = {"SUCCESS": "ok", "FAILURE": "bad", "ERROR": "bad", "PENDING": "warn", "EXPECTED": "warn"}.get(state or "", "")
    return _tag(f"{label} {(state or 'none').lower()}", css)


def _priority(name: Optional[str], order: List[str]) -> str:
    if not name:
        return ""
    index = order.index(name) if name in order else len(order)
    return _tag(name, "p0" if index == 0 else "p1" if index == 1 else "")


def _kind_mark(vocabulary: dict, token: Optional[str]) -> str:
    kind = next((k for k in vocabulary["kinds"] if k["token"] == token), None)
    style = f' style="--k:#{kind["color"]}"' if kind and kind["color"] else ""
    title = _e(kind["label"]) if kind else "unclassified"
    return f'<span class="k" title="{title}"{style}></span>'


def _needs_you(model: dict) -> str:
    rows = [f'<li class="alert">{_line(e, *[_tag(r, "warn") for r in e["reasons"]])}</li>' for e in model["needs_you"]]
    return _section("needs-you", "Needs you", _rows(rows, "Nothing needs you"), str(len(rows)))


def _health(model: dict) -> str:
    cap = model["soft_cap"]
    over = f"{cap['in_progress']} in progress, over the soft cap of {cap['cap']}"
    orphans = model["orphans"]
    groups = [
        ("Stale claims", [f'<li class="flag">{_line(r, _tag(r["branch"] or ""), _tag(_idle(r["idle_hours"]), "warn"))}</li>'
                          for r in model["stale"]]),
        ("Disagreements", [f'<li class="alert">{_line(d, _tag(d["kind"], "bad"), _tag(d["detail"]))}</li>'
                           for d in model["disagreements"]]),
        ("Orphans", [f'<li class="flag">{_line(None, _tag(o["reason"]), head="<code>" + _e(o["path"]) + "</code>")}</li>'
                     for o in orphans["worktrees"]]
         + [f'<li class="flag">{_line(None, _tag(o["reason"]), head="<code>" + _e(o["branch"]) + "</code>")}</li>'
            for o in orphans["branches"]]),
        ("Regressions", [f'<li class="alert">{_line(e)}</li>' for e in model["regressions"]]),
        ("Advisory CI", [f'<li class="alert">{_e(_ci_text(row))}</li>'
                         for row in model["ci"] if _ci_alert(row)]),
        ("Classification", [f'<li class="flag">{_line(p, _tag(p["problem"], "warn"))}</li>'
                            for p in model["classification"]]),
        ("Soft cap", [f'<li class="alert">{_line(None, head=_e(over))}</li>'] if cap["over"] else []),
    ]
    total = sum(len(items) for _, items in groups)
    clear = [title.lower() for title, items in groups if not items]
    body = ""
    for title, items in groups:
        if items:
            body += f'<div class="group">{_e(title)} · {len(items)}</div>' + "".join(items)
    if clear:
        body += f'<div class="clear">✓ clear: {_e(", ".join(clear))}</div>'
    return _section("health", "Health", f'<div class="panel rows">{body}</div>', f"{total} alert{'s' * (total != 1)}")


def _in_progress(model: dict, order: List[str]) -> str:
    cap = model["soft_cap"]
    rows = []
    for r in model["in_progress"]:
        pr = r["pr"]
        detail = [
            f"<div><span class=key>branch</span> <code>{_e(r['branch'])}</code></div>" if r["branch"] else "<div><span class=key>no claim branch</span></div>",
            f"<div><span class=key>worktree</span> <code>{_e(r['worktree'])}</code></div>" if r["worktree"] else "",
            f"<div><span class=key>session</span> <code>{_e(r['session'] or 'unknown')}</code></div>",
            f"<div><span class=key>last activity</span> {_e(_idle(r['idle_hours']))}</div>",
            (f"<div><span class=key>pull request</span> {_link(pr['url'], '#' + str(pr['number']) + ' ' + pr['title'])}"
             + (" (draft)" if pr["draft"] else "") + "</div>") if pr else "<div><span class=key>no pull request</span></div>",
        ]
        tags = (_tag(r["status"]), _priority(r.get("priority"), order),
                _check("checks", pr["checks"]) if pr else "", _check("verify", pr["verify"]) if pr else "",
                _tag("stale", "warn") if r["stale"] else _tag(_idle(r["idle_hours"])))
        rows.append(f'<li class="{"flag" if r["stale"] else ""}"><details><summary>{_line(r, *tags)}</summary>'
                    f'<div class="more">{"".join(detail)}</div></details></li>')
    count = f"{cap['in_progress']} / cap {cap['cap']}"
    return _section("in-progress", "In progress", _rows(rows, "Nothing in progress"), count)


def _work_row(row: dict, vocabulary: dict, order: List[str]) -> str:
    vis = row["visibility"] or ""
    status = "closed" if row["state"] != "OPEN" else (row["status"] or "no status")
    queue = f" · {row['queue']}" if row["queue"] else ""
    tags = (_priority(row["priority"], order), _tag(status + queue, "ok" if row["state"] != "OPEN" else ""),
            _tag("user-facing" if vis == "user-facing" else vis))
    kind = next((k["label"] for k in vocabulary["kinds"] if k["token"] == row["kind"]), "unclassified")
    detail = [
        f"<div>{_link(row['url'], 'Open on GitHub ↗')}</div>",
        f"<div><span class=key>kind</span> {_e(kind)} · <span class=key>visibility</span> {_e(vis or 'unclassified')}</div>",
        f"<div><span class=key>area</span> {_e(', '.join(row['areas']) or 'none')}</div>",
        f"<div><span class=key>epic</span> #{_e(row['epic'])}</div>" if row["epic"] else "",
        f"<div><span class=key>waits on</span> {_e(', '.join('#' + str(n) for n in row['open_blockers']))}</div>"
        if row["open_blockers"] else "",
        f"<div><span class=key>closed</span> {_e(row['closed_at'][:10])}</div>" if row["closed_at"] else "",
        f"<div><span class=key>labels</span> {_e(', '.join(row['labels']))}</div>" if row["labels"] else "",
    ]
    attrs = (f'data-n="{int(row["number"])}" data-kind="{_e(row["kind"] or "")}" data-vis="{_e(vis)}" '
             f'data-status="{_e(row["status_token"])}" data-area="{_e(" ".join(row["areas"]))}"')
    head = _kind_mark(vocabulary, row["kind"]) + _num(row) + _title(row)
    return (f'<li class="w" {attrs}><details><summary>{_line(row, *tags, head=head)}</summary>'
            f'<div class="more">{"".join(detail)}</div></details></li>')


def _chip(group: str, token: str, text: str, count: int, checked: bool = False) -> str:
    ident = f"f{group}-{token or 'none'}"
    return (f'<label class="chip"><input type="radio" name="f{group}" id="{_e(ident)}"'
            f'{" checked" if checked else ""}><span>{_e(text)}</span><small>{count}</small></label>')


def _work_section(model: dict, order: List[str]) -> Tuple[str, str]:
    vocabulary = model["vocabulary"]
    rows = model["work"]
    open_rows = [r for r in rows if r["state"] == "OPEN"]
    kinds = [(k["token"], k["token"]) for k in vocabulary["kinds"]]
    if any(r["kind"] is None for r in rows):
        kinds.append(("", "unclassified"))
    visibilities = [(v["token"], v["token"]) for v in vocabulary["visibilities"]]
    if any(r["visibility"] is None for r in rows):
        visibilities.append(("", "unclassified"))

    # Overview: open work by kind and visibility. Row headers set the kind filter.
    head = ("<tr><th>open</th>" + "".join(f'<th title="{_e(v)}">{_e(v.split("-")[0] if t else "none")}</th>' for t, v in visibilities)
            + "<th>all</th></tr>")
    body = ""
    for token, text in kinds:
        of_kind = [r for r in open_rows if (r["kind"] or "") == token]
        cells = "".join(
            (lambda n: f'<td class="{"z" if not n else ""}">{n or "·"}</td>')(
                sum(1 for r in of_kind if (r["visibility"] or "") == v)) for v, _ in visibilities)
        mark = _kind_mark(vocabulary, token or None)
        body += (f'<tr><th><label for="fk-{_e(token or "none")}">{mark}{_e(text)}</label></th>{cells}'
                 f"<td>{len(of_kind)}</td></tr>")
    totals = "".join(f"<td>{sum(1 for r in open_rows if (r['visibility'] or '') == v)}</td>" for v, _ in visibilities)
    body += f'<tr class="total"><th>total</th>{totals}<td>{len(open_rows)}</td></tr>'
    matrix = f'<div class="panel"><table class="matrix">{head}{body}</table></div>'

    def count(pred) -> int:
        return sum(1 for r in rows if pred(r))

    statuses = [(s["token"], s["label"]) for s in vocabulary["statuses"]
                if any(r["status_token"] == s["token"] for r in rows) and s["token"] != "closed"]
    # Kind, visibility and area counts are of open work, matching the default status filter.
    def open_count(pred) -> int:
        return sum(1 for r in open_rows if pred(r))

    filters = [
        ("kind", [_chip("k", "all", "all", len(open_rows), True)]
         + [_chip("k", t, x, open_count(lambda r, t=t: (r["kind"] or "") == t)) for t, x in kinds]),
        ("visible", [_chip("v", "all", "all", len(open_rows), True)]
         + [_chip("v", t, x, open_count(lambda r, t=t: (r["visibility"] or "") == t)) for t, x in visibilities]),
        ("status", [_chip("s", "open", "open", len(open_rows), True)]
         + [_chip("s", t, x.lower(), count(lambda r, t=t: r["status_token"] == t)) for t, x in statuses]
         + [_chip("s", "closed", f"closed {model['recent_days']}d", count(lambda r: r["state"] != "OPEN")),
            _chip("s", "all", "all", len(rows))]),
        ("area", [_chip("a", "all", "all", len(open_rows), True)]
         + [_chip("a", a["token"], a["token"], open_count(lambda r, t=a["token"]: t in r["areas"]))
            for a in vocabulary["areas"] if any(a["token"] in r["areas"] for r in rows)]),
    ]
    bar = '<div class="filters">' + "".join(
        f'<div class="frow" role="radiogroup" aria-label="{_e(name)}"><span class="flabel">{_e(name)}</span>'
        + "".join(chips) + "</div>" for name, chips in filters) + "</div>"

    # Filtering is CSS only: each checked radio hides the rows it excludes.
    rules = ['body:has(#fs-open:checked) .w[data-status="closed"]{display:none}']
    for token, _ in kinds:
        rules.append(f'body:has(#fk-{token or "none"}:checked) .w:not([data-kind="{token}"]){{display:none}}')
    for token, _ in visibilities:
        rules.append(f'body:has(#fv-{token or "none"}:checked) .w:not([data-vis="{token}"]){{display:none}}')
    for token, _ in statuses + [("closed", "")]:
        rules.append(f'body:has(#fs-{token}:checked) .w:not([data-status="{token}"]){{display:none}}')
    for area in vocabulary["areas"]:
        rules.append(f'body:has(#fa-{area["token"]}:checked) .w:not([data-area~="{area["token"]}"]){{display:none}}')

    items = [_work_row(r, vocabulary, order) for r in rows]
    listing = _rows(items, "No work")
    body_html = matrix + bar + listing
    return _section("work", "Work", body_html, f"{len(open_rows)} open"), "\n".join(rules)


def _epics(model: dict) -> str:
    by_epic: Dict[int, List[dict]] = {}
    for row in model["work"]:
        if row["epic"]:
            by_epic.setdefault(row["epic"], []).append(row)
    items = []
    for e in model["epics"]:
        percent = round(100 * e["completed"] / e["total"]) if e["total"] else 0
        children = by_epic.get(e["number"], [])
        child_html = "".join(
            f'<div>{_link(c["url"], "#" + str(c["number"]))} {_e(c["title"])} '
            f'<span class="tag">{_e("closed" if c["state"] != "OPEN" else (c["status"] or "no status"))}</span></div>'
            for c in children) or "<div>No open or recently closed tasks on the board</div>"
        rank = _tag(f"rank {e['rank']:g}") if e["rank"] is not None else ""
        bar = f'<span class="bar"><span style="width:{percent}%"></span></span>'
        line = _line(e, rank, _tag(f"{e['completed']}/{e['total']}"), head=_num(e) + _title(e) + bar)
        items.append(f'<li><details><summary>{line}</summary><div class="more">{child_html}</div></details></li>')
    return _section("epics", "Epics", _rows(items, "No epics"), str(len(items)))


def _ci_section(model: dict) -> str:
    if not model["ci"]:
        return ""
    rows = []
    for row in model["ci"]:
        url = row["url"] or ""
        link = f'<a href="{_e(url)}">run</a>' if url.startswith("https://") else ""
        jobs = " ".join(
            f'<a href="{_e(job["url"])}">{_e(name)}={_e(job["state"])}</a>'
            if (job["url"] or "").startswith("https://") else f'{_e(name)}={_e(job["state"])}'
            for name, job in row["jobs"].items())
        rows.append(f'<li>{_e(row["scope"])} {_e(row["branch"])} <code>{_e(row["sha"] or "unknown")}</code>'
                    f' {_e(row["state"])} {link}<div>{jobs}</div></li>')
    return _section("ci", "Advisory CI", '<div class="panel rows">' + "".join(rows) + '</div>',
                    "Latest main push and exact open PR heads; not failure history")


def render_html(model: dict) -> str:
    order = model.get("priority_order", [])
    cap = model["soft_cap"]
    alerts = (len(model["stale"]) + len(model["disagreements"]) + len(model["orphans"]["worktrees"])
              + len(model["orphans"]["branches"]) + len(model["regressions"]) + len(model["classification"])
              + int(cap["over"]) + sum(_ci_alert(row) for row in model["ci"]))
    open_work = sum(1 for r in model["work"] if r["state"] == "OPEN")
    closed = len(model["work"]) - open_work

    def tile(anchor: str, value: object, label: str, hot: bool = False) -> str:
        return (f'<a class="tile{" hot" if hot else ""}" href="#{anchor}"><b>{_e(value)}</b>'
                f"<span>{_e(label)}</span></a>")

    tiles = ('<nav class="tiles" aria-label="Overview">'
             + tile("needs-you", len(model["needs_you"]), "needs you", bool(model["needs_you"]))
             + tile("health", alerts, "alerts", bool(alerts))
             + tile("in-progress", f"{cap['in_progress']}/{cap['cap']}", "in progress", cap["over"])
             + tile("work", open_work, "open work")
             + tile("work", closed, f"closed {model['recent_days']}d")
             + tile("epics", len(model["epics"]), "epics") + "</nav>")
    work, rules = _work_section(model, order)
    stamp = model["generated_at"].replace("T", " ").replace("Z", " UTC")
    ignored = (f'<footer>Ignored {model["ignored_items"]} Project item(s) without an issue of this '
               "repository.</footer>" if model["ignored_items"] else "")
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="color-scheme" content="light dark">'
        f"<title>{_e(model['repository'])} work</title><style>{_CSS}{rules}</style></head><body>"
        f'<header><div class="brand">{_e(model["project"])} · work</div><h1>{_e(model["repository"])}</h1>'
        f'<div class="sub">Snapshot {_e(stamp)} · live from GitHub and Git when generated</div>'
        '<div class="stripe"></div></header>'
        + tiles + _needs_you(model) + _health(model) + _ci_section(model) + _in_progress(model, order) + work + _epics(model)
        + ignored + "</body></html>\n"
    )


# --------------------------------------------------------------------- run


def _commit_times(repo: Path, shas: List[str]) -> Dict[str, str]:
    if not shas:
        return {}
    completed = subprocess.run(["git", "show", "-s", "--format=%H %cI", *shas], cwd=repo,
                               capture_output=True, text=True)
    if completed.returncode != 0:
        raise DashboardError(f"git show failed: {completed.stderr.strip()}")
    return dict(line.split(" ", 1) for line in completed.stdout.splitlines() if line)


def run(gh: Gh, cwd: Path, config: dict, html_path: Optional[Path], json_path: Optional[Path]) -> int:
    rules = config["claim"]
    owner, name = gh.run("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    primary = start.primary_checkout(cwd).resolve()
    remote_claims = claims.all_claims(cwd, rules["remote"], rules["baseBranch"])
    worktrees = start.list_worktrees(cwd)
    times = _commit_times(cwd, sorted({c.sha for c in remote_claims}))
    # Worktree branches too: an orphan worktree's reason states its issue's real state.
    branches = [c.branch for c in remote_claims] + [b for b in worktrees.values() if b]
    numbers = {n for n in map(claims.claimed_issue, branches) if n is not None}
    github = fetch_github(gh, owner, name, config, numbers)
    snapshot = {
        **github,
        "claims": [{"branch": c.branch, "sha": c.sha, "session": c.session, "committed_at": times.get(c.sha)}
                   for c in remote_claims],
        "worktrees": [{"path": str(path), "branch": branch or None} for path, branch in worktrees.items()],
        "worktree_root": str((primary / rules["worktreeRoot"]).resolve()),
        "checkout_parent": str(primary.parent),
    }
    model = build(snapshot, config, datetime.now(timezone.utc))
    print(render_text(model), end="")
    for path, content in ((html_path, render_html(model)), (json_path, json.dumps(model, indent=2) + "\n")):
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {path}")
    return 0
