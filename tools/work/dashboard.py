"""`work dashboard`: one read-only view of all work, fetched live (README.md, `dashboard`).

`fetch_github` and the Git reads in `run` collect a snapshot; `build` turns
it into the model that `render_html`, `render_text` and `--json` present.
"""
from __future__ import annotations

import html
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePath
from typing import Callable, Dict, Iterable, List, Optional

import claim as claims
import start
from gh import Gh

# Workflow rule: a claim with no push or comment for this long is flagged.
STALE_AFTER = timedelta(hours=48)


class DashboardError(RuntimeError):
    pass


# ------------------------------------------------------------------ GitHub

_ISSUE_FIELDS = """
  number title url state
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
        number title url isDraft headRefName
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


def fetch_github(gh: Gh, owner: str, name: str, config: dict, claim_numbers: Iterable[int]) -> dict:
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
        elif state_of(number) != "OPEN":
            reason = _absence(number, state_of(number))
        else:
            reason = f"no remote claim branch for #{number}"
        orphan_worktrees.append({"path": relative, "branch": branch, "reason": reason})

    orphan_branches = [
        {"branch": c["branch"], "session": c["session"], "reason": _absence(n, state_of(n))}
        for n, cs in sorted(claims_by_issue.items()) if state_of(n) != "OPEN" for c in cs
    ]

    pulls = {}
    for node in sorted(snapshot["pull_requests"], key=lambda p: -p["number"]):
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
        if issue["status"] != rules["claimedStatus"] or not claimable(issue):
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
        if status != rules["claimedStatus"]:
            disagreements.append({**base, "kind": "claimed-not-in-progress",
                                  "detail": f"claim branch {owned[0]['branch']}; Status is "
                                            + (status or "unset or not in the Project")})
        if len(owned) > 1:
            disagreements.append({**base, "kind": "multiple-claims",
                                  "detail": "claim branches " + ", ".join(c["branch"] for c in owned)})
    for row in in_progress:
        if row["branch"] is None:
            disagreements.append({**{k: row[k] for k in ("number", "title", "url")},
                                  "kind": "in-progress-without-claim",
                                  "detail": f"Status is {rules['claimedStatus']} but no claim branch exists"})
    disagreements.sort(key=lambda d: (d["number"], d["kind"]))

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
        "ignored_items": ignored,
    }


def _absence(number: int, state: str) -> str:
    return {
        "CLOSED": f"issue #{number} is closed",
        "PULL_REQUEST": f"#{number} is a pull request, not an issue",
    }.get(state, f"issue #{number} does not exist")


# ---------------------------------------------------------------- rendering


def _idle(hours: Optional[float]) -> str:
    if hours is None:
        return "no activity"
    if hours < 1:
        return f"{int(hours * 60)}m ago"
    if hours < 48:
        return f"{int(hours)}h ago"
    return f"{int(hours // 24)}d ago"


def render_text(model: dict) -> str:
    cap = model["soft_cap"]
    lines = [f"{model['repository']} - Project {model['project']!r} - {model['generated_at']}"]

    def section(title: str, rows: List[str]) -> None:
        lines.append(f"{title} ({len(rows)})")
        lines.extend("  " + row for row in rows)

    section("Needs you", [f"#{e['number']} {e['title']} [{', '.join(e['reasons'])}]" for e in model["needs_you"]])
    section("Epics", [f"#{e['number']} {e['title']} {e['completed']}/{e['total']}" for e in model["epics"]])
    section(f"In progress, soft cap {cap['cap']}" + (" EXCEEDED" if cap["over"] else ""), [
        f"#{r['number']} {r['branch'] or '(no claim branch)'} session {r['session'] or '?'} "
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
    if model["ignored_items"]:
        lines.append(f"Ignored {model['ignored_items']} Project item(s) without an issue of this repository")
    return "\n".join(lines) + "\n"


def _numbers(numbers: List[int]) -> str:
    return ", ".join(f"#{n}" for n in numbers)


_CSS = """
:root{color-scheme:light dark;--bg:#fff;--fg:#1f2328;--muted:#59636e;--card:#f6f8fa;--line:#d1d9e0;
--accent:#0969da;--good:#1a7f37;--warn:#9a6700;--bad:#cf222e}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--card:#151b23;
--line:#3d444d;--accent:#4493f8;--good:#3fb950;--warn:#d29922;--bad:#f85149}}
*{box-sizing:border-box}
body{margin:0 auto;max-width:760px;padding:12px;background:var(--bg);color:var(--fg);
font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;overflow-wrap:anywhere}
h1{font-size:19px;margin:4px 0}
h2{font-size:15px;margin:20px 0 8px;display:flex;gap:8px;align-items:center}
.sub,.empty,.meta{color:var(--muted);font-size:13px}
.count{font-size:12px;font-weight:600;border:1px solid var(--line);border-radius:10px;padding:0 7px}
ul{list-style:none;margin:0;padding:0}
li{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 10px;margin:0 0 6px}
li.flag{border-left:4px solid var(--warn)}
li.alert{border-left:4px solid var(--bad)}
a{color:var(--accent);text-decoration:none}
.num{font-weight:600;margin-right:4px}
.meta{margin-top:3px;display:flex;flex-wrap:wrap;gap:4px 10px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
.chip{font-size:12px;border:1px solid var(--line);border-radius:10px;padding:0 6px}
.over{color:var(--bad)}
.SUCCESS{color:var(--good)}.FAILURE,.ERROR{color:var(--bad)}.PENDING,.EXPECTED{color:var(--warn)}
.bar{height:6px;background:var(--line);border-radius:3px;margin-top:6px;overflow:hidden}
.bar span{display:block;height:100%;background:var(--good)}
"""


def _e(value: object) -> str:
    return html.escape(str(value), quote=True)


def _link(url: Optional[str], text: str) -> str:
    # Only GitHub's own https URLs become links; anything else is plain text.
    if url and url.startswith("https://"):
        return f'<a href="{_e(url)}">{_e(text)}</a>'
    return _e(text)


def _head(entry: dict) -> str:
    title = entry.get("title")
    return (f'<div><span class="num">{_link(entry.get("url"), "#" + str(entry["number"]))}</span>'
            + (_e(title) if title else '<span class="sub">not in the Project</span>') + "</div>")


def _meta(*parts: str) -> str:
    kept = [p for p in parts if p]
    return f'<div class="meta">{"".join(kept)}</div>' if kept else ""


def _chip(text: str, css: str = "") -> str:
    return f'<span class="chip {_e(css)}">{_e(text)}</span>'


def _state(label: str, state: Optional[str]) -> str:
    return _chip(f"{label} {state.lower() if state else 'none'}", state or "")


def _code(value: Optional[str]) -> str:
    return f"<code>{_e(value)}</code>" if value else ""


def _span(text: str) -> str:
    return f"<span>{_e(text)}</span>"


def _labels(entry: dict) -> str:
    return "".join(_chip(label) for label in entry.get("labels", []))


def _item(entry: Optional[dict], *meta: object, css: str = "", head: str = "", tail: str = "") -> str:
    """One card: a heading line, one meta line per argument (a string or a tuple of parts), then tail."""
    lines = [head or _head(entry)] + [_meta(*line) if isinstance(line, tuple) else _meta(line) for line in meta]
    return f'<li class="{css}">' + "".join(lines) + tail + "</li>"


def _section(title: str, items: List[str], note: str = "") -> str:
    body = "<ul>" + "".join(items) + "</ul>" if items else '<p class="empty">None</p>'
    extra = f'<span class="sub">{_e(note)}</span>' if note else ""
    return f'<section><h2>{_e(title)} <span class="count">{len(items)}</span>{extra}</h2>{body}</section>'


def _rank(rank: Optional[float]) -> str:
    return _chip(f"rank {rank:g}") if rank is not None else ""


def _in_progress(row: dict) -> str:
    pr = row["pr"]
    claim_line = (
        _code(row["branch"]) if row["branch"] else _chip("no claim branch", "FAILURE"),
        _code(row["worktree"]),
        "<span>session " + (_code(row["session"]) or "unknown") + "</span>",
        _span(_idle(row["idle_hours"])),
        _chip("stale", "PENDING") if row["stale"] else "",
    )
    if pr:
        pr_line = (_link(pr["url"], f"PR #{pr['number']}"), _chip("draft") if pr["draft"] else "",
                   _state("checks", pr["checks"]), _state("verify", pr["verify"]))
    else:
        pr_line = (_span("no PR"),)
    return _item(row, claim_line, pr_line, css="flag" if row["stale"] else "")


def render_html(model: dict) -> str:
    cap = model["soft_cap"]
    needs_you = [_item(e, tuple(_chip(r) for r in e["reasons"]) + (_labels(e),), css="alert")
                 for e in model["needs_you"]]
    epics = []
    for e in model["epics"]:
        percent = round(100 * e["completed"] / e["total"]) if e["total"] else 0
        bar = f'<div class="bar"><span style="width:{percent}%"></span></div>'
        epics.append(_item(e, (_rank(e["rank"]), _chip(e["status"] or "no status"),
                               _span(f"{e['completed']}/{e['total']} done")), tail=bar))
    ready = [
        _item(e, (_chip(e["priority"]) if e["priority"] else "", _rank(e["rank"]),
                  _span(f"epic #{e['epic']}") if e["epic"] else "",
                  _chip("waits on " + _numbers(e["open_blockers"]), "PENDING") if e["open_blockers"] else ""))
        for e in model["ready"]
    ]
    blocked = [_item(e, _labels(e), css="flag") for e in model["blocked"]]
    stale = [_item(r, (_code(r["branch"]), _span(r["session"] or ""), _span(_idle(r["idle_hours"]))), css="flag")
             for r in model["stale"]]
    disagreements = [_item(d, (_chip(d["kind"]), _span(d["detail"])), css="alert") for d in model["disagreements"]]
    orphans = (
        [_item(None, (_code(o["branch"]) or _span("detached"), _span(o["reason"])), css="flag",
               head="<div>worktree " + _code(o["path"]) + "</div>")
         for o in model["orphans"]["worktrees"]]
        + [_item(None, _span(o["reason"]), css="flag", head="<div>branch " + _code(o["branch"]) + "</div>")
           for o in model["orphans"]["branches"]]
    )
    regressions = [_item(e, _labels(e), css="alert") for e in model["regressions"]]
    over = " - over the cap" if cap["over"] else ""
    cap_line = (f'<p class="{"over" if cap["over"] else "sub"}">{cap["in_progress"]} in progress, '
                f'soft cap {cap["cap"]}{over}</p>')
    ignored = (f'<p class="sub">Ignored {model["ignored_items"]} Project item(s) without an issue of this '
               "repository.</p>" if model["ignored_items"] else "")
    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="color-scheme" content="light dark">'
        f"<title>{_e(model['repository'])} work</title><style>{_CSS}</style></head><body>"
        f"<header><h1>{_e(model['repository'])}</h1>"
        f'<p class="sub">Project {_e(model["project"])} - {_e(model["generated_at"])}</p></header>'
        + _section("Needs you", needs_you)
        + _section("Epics", epics)
        + _section("In progress", [_in_progress(r) for r in model["in_progress"]])
        + _section("Ready queue", ready)
        + _section("Blocked", blocked)
        + _section("Stale claims", stale, "no push or comment for 48h")
        + f"<section><h2>Soft cap</h2>{cap_line}</section>"
        + _section("Disagreements", disagreements)
        + _section("Orphans", orphans)
        + _section("Regressions", regressions)
        + ignored
        + "</body></html>\n"
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
    times = _commit_times(cwd, sorted({c.sha for c in remote_claims}))
    github = fetch_github(gh, owner, name, config, [claims.claimed_issue(c.branch) for c in remote_claims])
    snapshot = {
        **github,
        "claims": [{"branch": c.branch, "sha": c.sha, "session": c.session, "committed_at": times.get(c.sha)}
                   for c in remote_claims],
        "worktrees": [{"path": str(path), "branch": branch or None}
                      for path, branch in start.list_worktrees(cwd).items()],
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
