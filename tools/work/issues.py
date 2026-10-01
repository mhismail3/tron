"""`work issues`: a complete, bounded issue corpus for related-issue checks (README.md, `issues`)."""
from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor
from typing import List

from gh import Gh

# The corpus is printed to stdout and read back by an agent tool whose output
# limit is 1 MiB, so every field is capped and the whole document is bounded.
OPEN_LIMIT = 500
CLOSED_LIMIT_MAX = 500
TITLE_CHARS = 200
BODY_CHARS = 1000
MAX_OUTPUT_BYTES = 900_000

_FIELDS = "number,title,body,labels,state,stateReason,closedAt"
_COMMENT = re.compile(r"<!--.*?-->", re.S)
_HEADING = re.compile(r"^#+\s.*$", re.M)
_SPACE = re.compile(r"\s+")


class IssuesError(RuntimeError):
    pass


def normalize_body(body: str) -> str:
    """Drop form scaffolding (comments, headings, empty answers) so the excerpt is the author's text."""
    text = _COMMENT.sub(" ", body or "")
    text = _HEADING.sub(" ", text).replace("_No response_", " ")
    return _SPACE.sub(" ", text).strip()[:BODY_CHARS]


def _entry(raw: dict, epic_label: str) -> dict:
    labels = [label["name"] for label in raw.get("labels") or []]
    return {
        "number": raw["number"],
        "state": raw["state"].lower(),
        "stateReason": (raw.get("stateReason") or "").lower() or None,
        "closedAt": raw.get("closedAt") or None,
        "epic": epic_label in labels,
        "title": _SPACE.sub(" ", raw.get("title") or "").strip()[:TITLE_CHARS],
        "labels": labels,
        "body": normalize_body(raw.get("body") or ""),
    }


def _list(gh: Gh, state: str, limit: int, *extra: str) -> List[dict]:
    return json.loads(gh.run("issue", "list", "--state", state, "--limit", str(limit), "--json", _FIELDS, *extra))


def collect(gh: Gh, config: dict, closed_limit: int) -> dict:
    """Every open issue, plus the `closed_limit` most recently updated closed ones; complete or an error."""
    if not 0 <= closed_limit <= CLOSED_LIMIT_MAX:
        raise IssuesError(f"--closed-limit must be between 0 and {CLOSED_LIMIT_MAX}")
    epic_label = config["dashboard"]["epicLabel"]
    # One more than the limit proves the list is complete; a silently truncated
    # corpus would report "no related issue" for an issue it never saw.
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending_open = pool.submit(_list, gh, "open", OPEN_LIMIT + 1)
        pending_closed = pool.submit(_list, gh, "closed", closed_limit, "--search", "sort:updated-desc") if closed_limit else None
        opened = pending_open.result()
        closed = pending_closed.result() if pending_closed else []
    if len(opened) > OPEN_LIMIT:
        raise IssuesError(f"more than {OPEN_LIMIT} open issues; the corpus would be incomplete")
    issues = [_entry(raw, epic_label) for raw in opened + closed]
    corpus = {"open": len(opened), "closed": len(closed), "issues": issues}
    if len(json.dumps(corpus).encode()) > MAX_OUTPUT_BYTES:
        raise IssuesError("issue corpus exceeds its output bound; lower --closed-limit")
    return corpus


def run(gh: Gh, config: dict, closed_limit: int) -> int:
    print(json.dumps(collect(gh, config, closed_limit), ensure_ascii=False))
    return 0
