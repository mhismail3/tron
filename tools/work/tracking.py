"""Typed issue, Project and native relationship writes for agent work."""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from contextlib import nullcontext
from datetime import date
from pathlib import Path
from typing import Callable, List, Optional, Tuple
from urllib.parse import quote

import bootstrap
import claim as claims
import comments
import start
from gh import Gh, GhError


class TrackingError(RuntimeError):
    pass


_PROJECT_ITEMS = """
query($issue: ID!, $cursor: String) {
  node(id: $issue) {
    ... on Issue {
      projectItems(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id project { ... on ProjectV2 { id title } } }
      }
    }
  }
}
"""

_RELATIONS = """
query($issue: ID!) {
  node(id: $issue) {
    ... on Issue {
      subIssues(first: 100) { nodes { id } }
      blockedBy(first: 100) { nodes { id } }
    }
  }
}
"""

_UPDATE_FIELD = (
    "mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) { "
    "updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, "
    "value: {singleSelectOptionId: $option}}) { projectV2Item { id } } }"
)


def _scrub(repo: Path, config: dict, text: str, purpose: str) -> None:
    command = config.get("verify", {}).get("scrubCommand")
    if not isinstance(command, str) or not command.strip():
        raise TrackingError("public issue text requires the configured privacy guard")
    try:
        result = subprocess.run(["bash", "-c", command], cwd=repo, input=text,
                                capture_output=True, text=True)
    except OSError as error:
        raise TrackingError(f"privacy guard could not run for {purpose}") from error
    if result.returncode:
        raise TrackingError(f"{purpose} refused by the privacy guard")


def _issue(gh: Gh, repository: str, number: int) -> dict:
    if number <= 0:
        raise TrackingError("issue numbers must be positive")
    try:
        issue = gh.rest("GET", f"repos/{repository}/issues/{number}")
    except GhError as error:
        raise TrackingError(f"could not load issue #{number}") from error
    if not isinstance(issue, dict) or issue.get("number") != number or "pull_request" in issue:
        raise TrackingError(f"#{number} is not an issue in this repository")
    return issue


def _repository(gh: Gh) -> Tuple[str, str]:
    try:
        data = json.loads(gh.run("repo", "view", "--json", "nameWithOwner,owner"))
        owner, name = data["nameWithOwner"].split("/", 1)
    except (GhError, KeyError, ValueError, json.JSONDecodeError) as error:
        raise TrackingError("could not resolve the current repository") from error
    return owner, name


# Title prefixes the retired issue templates added; labels carry the type and kind.
_TEMPLATE_PREFIX = re.compile(r"^\s*\[[^\]]{1,20}\]:?\s|^\s*(Task|Bug|Feature|Epic):\s", re.IGNORECASE)
# An issue that waits for the next failure or recurrence lives forever unless it names when to stop waiting.
_WAITS_FOR_RECURRENCE = re.compile(
    r"next (failure|occurrence|recurrence|time it (fails|happens))|if it (recurs|reappears|happens again)"
    r"|until it (recurs|reproduces|happens again)|wait(ing)? for (it to recur|a recurrence|the next)", re.IGNORECASE)
EXIT_LINE = re.compile(r"^Exit by: (\d{4}-\d{2}-\d{2})\b", re.MULTILINE)


def create_issue(gh: Gh, repo: Path, config: dict, title: str, body_file: Path, issue_type: str,
                 kind: Optional[str], areas: Optional[List[str]], status: Optional[str] = None,
                 priority: Optional[str] = None, exit_by: Optional[str] = None) -> int:
    """File an issue that is classified and on the Project in one command; every check runs before any write."""
    title = title.strip()
    if not title or len(title) > 200:
        raise TrackingError("issue title must contain 1 to 200 characters")
    if _TEMPLATE_PREFIX.search(title):
        raise TrackingError("drop the title prefix (for example [Task]:); labels carry the type and kind")
    if issue_type not in {"task", "epic"}:
        raise TrackingError("issue type must be task or epic")
    try:
        body = body_file.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise TrackingError("could not read the issue body file") from error
    if not body.strip():
        raise TrackingError("issue body must not be empty")
    if exit_by is not None:
        try:
            when = date.fromisoformat(exit_by)
        except ValueError as error:
            raise TrackingError("--exit-by must be a YYYY-MM-DD date") from error
        if when <= date.today():
            raise TrackingError("--exit-by must be a future date")
        body = body.rstrip() + f"\n\nExit by: {when.isoformat()}. Close as not planned if it has not recurred by then.\n"
    elif _WAITS_FOR_RECURRENCE.search(title + "\n" + body) and not EXIT_LINE.search(body):
        raise TrackingError("this issue waits for a recurrence; give it an exit with --exit-by YYYY-MM-DD "
                            "(the date after which it closes as not planned)")
    if len(body.encode("utf-8")) > 64 * 1024:
        raise TrackingError("issue body exceeds the 64 KiB bound")

    declared = {label["name"] for label in config["labels"]}
    board = config["dashboard"]
    labels: List[str] = []
    if issue_type == "task":
        # Every task is classified at filing: exactly one kind and at least one area.
        if not kind:
            raise TrackingError("a task needs --kind with one declared kind: label")
        if not kind.startswith(board["kindPrefix"]) or kind not in declared:
            raise TrackingError(f"{kind!r} is not a declared kind label")
        if not areas:
            raise TrackingError("a task needs at least one --area with a declared area: label")
        for area in areas:
            if not area.startswith(board["areaPrefix"]) or area not in declared:
                raise TrackingError(f"{area!r} is not a declared area label")
        if len(set(areas)) != len(areas):
            raise TrackingError("task area labels must be unique")
        labels = [kind, *areas]
    else:
        if kind is not None or areas:
            raise TrackingError("epics do not take kind or area labels")
        labels = [board["epicLabel"]]
    status = status or config["claim"]["readyStatus"]
    _check_options(config, status, priority)
    _scrub(repo, config, title + "\n\n" + body, "issue title and body")
    owner, name = _repository(gh)
    _, project = _project(gh, repo, config)  # resolved before filing, so a missing Project refuses first
    response = gh.rest("POST", f"repos/{owner}/{name}/issues", {"title": title, "body": body, "labels": labels})
    if not isinstance(response, dict) or not isinstance(response.get("number"), int):
        raise TrackingError("GitHub did not return the created issue number")
    number = response["number"]
    print(f"created issue #{number}")
    try:
        item = gh.graphql(
            "mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: "
            "{projectId: $project, contentId: $content}) { item { id } } }",
            project=project["id"], content=response["node_id"])["addProjectV2ItemById"]["item"]["id"]
        _write_fields(gh, project, item, number, status, priority)
    except (GhError, KeyError, TypeError) as error:
        raise TrackingError(f"created #{number}, but its Project membership is incomplete; finish with "
                            f"work project add {number} and work project set {number} --status {status}") from error
    return number


def edit_issue(gh: Gh, repo: Path, config: dict, number: int, title: Optional[str], body_file: Optional[Path]) -> None:
    """Replace an issue's title and/or body, for example to name only the remaining scope."""
    update = {}
    if title is not None:
        title = title.strip()
        if not title or len(title) > 200:
            raise TrackingError("issue title must contain 1 to 200 characters")
        update["title"] = title
    if body_file is not None:
        try:
            body = body_file.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise TrackingError("could not read the issue body file") from error
        if not body.strip() or len(body.encode("utf-8")) > 64 * 1024:
            raise TrackingError("issue body must be non-empty and at most 64 KiB")
        update["body"] = body
    if not update:
        raise TrackingError("provide --title or --body-file")
    _scrub(repo, config, "\n\n".join(update.values()), "issue title and body")
    owner, name = _repository(gh)
    _issue(gh, f"{owner}/{name}", number)
    gh.rest("PATCH", f"repos/{owner}/{name}/issues/{number}", update)
    print(f"updated issue #{number}: {', '.join(update)}")


def _check_options(config: dict, status: Optional[str], priority: Optional[str]) -> None:
    declared_fields = {field["name"]: field for field in config["project"]["fields"]}
    for name, value in ((config["claim"]["statusField"], status), (config["dashboard"]["priorityField"], priority)):
        if value is None:
            continue
        field = declared_fields.get(name)
        options = {option["name"] for option in field.get("options", [])} if field else set()
        if value not in options:
            raise TrackingError(f"{value!r} is not a declared {name} option")


def set_labels(gh: Gh, config: dict, number: int, additions: List[str], removals: List[str]) -> None:
    if not additions and not removals:
        raise TrackingError("provide at least one --add or --remove label")
    if set(additions) & set(removals):
        raise TrackingError("a label cannot be both added and removed")
    declared = {label["name"] for label in config["labels"]}
    if set(additions) - declared:
        raise TrackingError("only labels declared in .github/work.json may be added")
    if config["dashboard"]["epicLabel"] in (set(additions) | set(removals)):
        raise TrackingError("the epic label is fixed at creation")
    if number <= 0:
        raise TrackingError("issue numbers must be positive")

    taxonomy_prefixes = ("kind:", "area:")
    changes_taxonomy = any(label.startswith(taxonomy_prefixes)
                           for label in additions + removals)
    owner, name = _repository(gh)
    lock = gh.taxonomy_labels_lock() if changes_taxonomy else nullcontext()
    with lock:
        issue = _issue(gh, f"{owner}/{name}", number)
        current = [label["name"] for label in issue.get("labels", [])]
        updated = [label for label in current if label not in removals]
        updated.extend(label for label in additions if label not in updated)
        if "epic" not in updated:
            # A task holds one kind; areas may repeat.
            for prefix in taxonomy_prefixes:
                classified = [label for label in updated if label.startswith(prefix)]
                if any(label not in declared for label in classified):
                    raise TrackingError(f"issue labels hold an undeclared {prefix[:-1]} label")
                if prefix != "area:" and len(classified) > 1:
                    raise TrackingError(f"an issue holds at most one {prefix[:-1]} label")
        additions_needed = [label for label in additions if label not in current]
        removals_needed = [label for label in removals if label in current]
        if not additions_needed and not removals_needed:
            print(f"labels unchanged on issue #{number}")
            return

        completed: List[str] = []
        try:
            if additions_needed:
                gh.rest("POST", f"repos/{owner}/{name}/issues/{number}/labels",
                        {"labels": additions_needed})
                completed.extend(f"added {label}" for label in additions_needed)
            for label in removals_needed:
                gh.rest("DELETE", f"repos/{owner}/{name}/issues/{number}/labels/{quote(label, safe='')}")
                completed.append(f"removed {label}")
        except GhError as error:
            if completed:
                raise TrackingError(f"{', '.join(completed)}; next label mutation failed or is uncertain") from error
            raise TrackingError("issue label mutation failed or is uncertain") from error
    print(f"updated labels on issue #{number}")


def _project(gh: Gh, repo: Path, config: dict) -> tuple[bootstrap.Bootstrap, dict]:
    manager = bootstrap.Bootstrap(gh, repo, config)
    _, projects = manager._projects()
    matches = [project for project in projects if project["title"] == config["project"]["title"]]
    if len(matches) != 1:
        raise TrackingError("the configured work Project is missing or ambiguous; run work bootstrap")
    project = matches[0]
    repository_ids = {entry["id"] for entry in project["repositories"]["nodes"]}
    if manager.repo_id not in repository_ids:
        raise TrackingError("the configured Project is not linked to this repository; run work bootstrap")
    return manager, project


def _project_items(gh: Gh, issue_id: str) -> List[dict]:
    found: List[dict] = []
    cursor = None
    while True:
        items = gh.graphql(_PROJECT_ITEMS, issue=issue_id, cursor=cursor)["node"]["projectItems"]
        found.extend(items["nodes"])
        if not items["pageInfo"]["hasNextPage"]:
            return found
        cursor = items["pageInfo"]["endCursor"]


def add_project_item(gh: Gh, repo: Path, config: dict, number: int) -> None:
    owner, name = _repository(gh)
    issue = _issue(gh, f"{owner}/{name}", number)
    _, project = _project(gh, repo, config)
    if any(item["project"]["id"] == project["id"] for item in _project_items(gh, issue["node_id"])):
        print(f"issue #{number} is already in the work Project")
        return
    query = (
        "mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: "
        "{projectId: $project, contentId: $content}) { item { id } } }"
    )
    gh.graphql(query, project=project["id"], content=issue["node_id"])
    print(f"added issue #{number} to the work Project")


def set_project_fields(gh: Gh, repo: Path, config: dict, number: int,
                       status: Optional[str], priority: Optional[str]) -> None:
    if status is None and priority is None:
        raise TrackingError("provide --status or --priority")
    _check_options(config, status, priority)

    owner, name = _repository(gh)
    issue = _issue(gh, f"{owner}/{name}", number)
    _, project = _project(gh, repo, config)
    items = [item for item in _project_items(gh, issue["node_id"])
             if item["project"]["id"] == project["id"]]
    if not items:
        raise TrackingError(f"issue #{number} is not in the work Project; run work project add first")
    _write_fields(gh, project, items[0]["id"], number, status, priority)


def _write_fields(gh: Gh, project: dict, item_id: str, number: int,
                  status: Optional[str], priority: Optional[str]) -> None:
    field_map = {field["name"]: field for field in project["fields"]["nodes"] if field}
    resolved: List[Tuple[str, str, str]] = []
    for field_name, value in (("Status", status), ("Priority", priority)):
        if value is None:
            continue
        field = field_map.get(field_name)
        option = next((option["id"] for option in (field or {}).get("options", [])
                       if option["name"] == value), None)
        if not field or option is None:
            raise TrackingError(f"Project has no configured {field_name} option {value!r}; run work bootstrap")
        resolved.append((field_name, field["id"], option))

    completed: List[str] = []
    for field_name, field_id, option_id in resolved:
        try:
            gh.graphql(_UPDATE_FIELD, project=project["id"], item=item_id,
                       field=field_id, option=option_id)
        except GhError as error:
            if completed:
                raise TrackingError(f"{', '.join(completed)} updated; {field_name} failed or is uncertain") from error
            raise TrackingError(f"{field_name} failed or is uncertain") from error
        completed.append(field_name)
    print(f"updated issue #{number} Project fields: {', '.join(completed)}")


def _relation(gh: Gh, issue_id: str) -> dict:
    result = gh.graphql(_RELATIONS, issue=issue_id)["node"]
    return result


def add_parent(gh: Gh, repo: Path, config: dict, child_number: int, epic_number: int,
               replace_parent: bool = False) -> None:
    owner, name = _repository(gh)
    child = _issue(gh, f"{owner}/{name}", child_number)
    epic = _issue(gh, f"{owner}/{name}", epic_number)
    child_labels = {label["name"] for label in child.get("labels", [])}
    epic_labels = {label["name"] for label in epic.get("labels", [])}
    epic_label = config["dashboard"]["epicLabel"]
    if child_number == epic_number or epic_label in child_labels or epic_label not in epic_labels:
        raise TrackingError("parent links require a task child and an epic parent")
    if any(node["id"] == child["node_id"] for node in _relation(gh, epic["node_id"])["subIssues"]["nodes"]):
        print(f"issue #{child_number} is already a sub-issue of #{epic_number}")
        return
    gh.graphql(
        # GitHub allows one parent; moving a task to another epic must say so explicitly.
        "mutation($epic: ID!, $child: ID!, $replace: Boolean!) { addSubIssue(input: "
        "{issueId: $epic, subIssueId: $child, replaceParent: $replace}) { issue { id } } }",
        epic=epic["node_id"], child=child["node_id"], replace=replace_parent,
    )
    print(f"linked issue #{child_number} under epic #{epic_number}")


def add_blocker(gh: Gh, repo: Path, config: dict, issue_number: int, blocker_number: int) -> None:
    if issue_number == blocker_number:
        raise TrackingError("an issue cannot block itself")
    owner, name = _repository(gh)
    issue = _issue(gh, f"{owner}/{name}", issue_number)
    blocker = _issue(gh, f"{owner}/{name}", blocker_number)
    if any(node["id"] == blocker["node_id"] for node in _relation(gh, issue["node_id"])["blockedBy"]["nodes"]):
        print(f"issue #{issue_number} is already blocked by #{blocker_number}")
        return
    gh.graphql(
        "mutation($issue: ID!, $blocker: ID!) { addBlockedBy(input: "
        "{issueId: $issue, blockingIssueId: $blocker}) { issue { id } } }",
        issue=issue["node_id"], blocker=blocker["node_id"],
    )
    print(f"linked blocker #{blocker_number} to issue #{issue_number}")


def open_sub_issues(gh: Gh, repository: str, number: int) -> List[int]:
    """Open sub-issue numbers of an issue, read from every page: a finished first page is not a finished epic."""
    children = gh.rest_pages(f"repos/{repository}/issues/{number}/sub_issues?per_page=100")
    return [child["number"] for child in children if child.get("state") != "closed"]


_CLOSE_REASONS = {"completed": "completed", "not_planned": "not planned"}


def _close_marker(reason: str, text: str) -> str:
    # One close is identified by its reason and exact public text: a re-run of
    # the same close finds its comment, while a new close after a reopen posts its own.
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return f"<!-- work:close reason={reason} digest={digest} -->"


def _finish_step(finished: List[str], done: str, failed: str, action: Callable[[], object]) -> None:
    try:
        action()
    except GhError as error:
        if finished:
            raise TrackingError(f"completed: {'; '.join(finished)}; {failed} failed or is uncertain; "
                                "re-run the same command to finish") from error
        raise TrackingError(f"{failed} failed or is uncertain") from error
    finished.append(done)


def close_issue(gh: Gh, repo: Path, config: dict, number: int, reason: str, comment_file: Path) -> None:
    """Comment, close and set Status Done without claiming or changing Git work.

    Issue state retires the active claim; deleting its branch/worktree belongs to
    cleanup, which proves the work is preserved. Closure needs no owner lookup.
    Re-running after a partial failure is safe: a comment already posted for this
    reason and text is not posted again, even if someone else closed the issue.
    """
    if number <= 0:
        raise TrackingError("issue numbers must be positive")
    text = comments.prepared_body(repo, config, comment_file)
    marker = _close_marker(reason, text)
    rules = config["claim"]
    owner, name = _repository(gh)
    repository = f"{owner}/{name}"
    issue = _issue(gh, repository, number)
    labels = {label["name"] for label in issue.get("labels", [])}
    if config["dashboard"]["epicLabel"] in labels:
        # Read every page before any write; a finished first page is not a finished epic.
        unfinished = open_sub_issues(gh, repository, number)
        if unfinished:
            raise TrackingError(f"#{number} has unfinished sub-issues: "
                                + ", ".join(f"#{child}" for child in unfinished))
    posted = any(marker in (comment.get("body") or "")
                 for comment in gh.rest_pages(f"repos/{repository}/issues/{number}/comments"))
    is_open = issue.get("state") == "open"
    done_status = config["land"]["doneStatus"]
    _, project = _project(gh, repo, config)
    items = [item for item in _project_items(gh, issue["node_id"]) if item["project"]["id"] == project["id"]]
    status_item = None
    if items:
        field = next((f for f in project["fields"]["nodes"] if f and f["name"] == rules["statusField"]), None)
        if field is None or done_status not in {option["name"] for option in field.get("options", [])}:
            raise TrackingError(f"Project has no configured {rules['statusField']} option {done_status!r}; "
                                "run work bootstrap")
        status_item = {"id": items[0]["id"], "project": {"id": project["id"], "field": field}}

    finished: List[str] = []
    if not posted:
        _finish_step(finished, "comment posted", "comment",
                     lambda: gh.run("issue", "comment", str(number), "--body-file", "-", stdin=text + marker + "\n"))
    if is_open:
        _finish_step(finished, "issue closed", "close",
                     lambda: gh.run("issue", "close", str(number), "--reason", _CLOSE_REASONS[reason]))
    if status_item is not None:
        _finish_step(finished, f"Status set to {done_status}", "Status update",
                     lambda: start.set_status(gh, status_item, done_status))
    print(f"closed issue #{number} as {_CLOSE_REASONS[reason]}")


def reopen_issue(gh: Gh, repo: Path, config: dict, number: int, comment_file: Path) -> None:
    """Post the stated reason, reopen, and restore Status, refusing before any write.

    The reason comment is required and carries an audit marker, so a re-run after a
    partial failure finds it and finishes the reopen instead of posting it again.
    Claims are left as they are: reopening returns work to its owner, if any.
    """
    if number <= 0:
        raise TrackingError("issue numbers must be positive")
    text = comments.prepared_body(repo, config, comment_file)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    marker = f"<!-- work:reopen digest={digest} -->"
    rules = config["claim"]
    owner, name = _repository(gh)
    repository = f"{owner}/{name}"
    issue = _issue(gh, repository, number)
    posted = any(marker in (comment.get("body") or "")
                 for comment in gh.rest_pages(f"repos/{repository}/issues/{number}/comments"))
    is_closed = issue.get("state") != "open"
    if not is_closed and not posted:
        raise TrackingError(f"#{number} is open; work issue reopen only finishes a reopen it started")
    claimed = claims.existing_claims(repo, rules["remote"], rules["baseBranch"], number)
    status = rules["claimedStatus"] if claimed else rules["readyStatus"]

    _, project = _project(gh, repo, config)
    items = [item for item in _project_items(gh, issue["node_id"]) if item["project"]["id"] == project["id"]]
    status_item = None
    if items:
        field = next((f for f in project["fields"]["nodes"] if f and f["name"] == rules["statusField"]), None)
        if field is None or status not in {option["name"] for option in field.get("options", [])}:
            raise TrackingError(f"Project has no configured {rules['statusField']} option {status!r}; "
                                "run work bootstrap")
        status_item = {"id": items[0]["id"], "project": {"id": project["id"], "field": field}}

    finished: List[str] = []
    if not posted:
        _finish_step(finished, "reason posted", "comment",
                     lambda: gh.run("issue", "comment", str(number), "--body-file", "-", stdin=text + marker + "\n"))
    if is_closed:
        _finish_step(finished, "issue reopened", "reopen", lambda: gh.run("issue", "reopen", str(number)))
    if status_item is not None:
        _finish_step(finished, f"Status set to {status}", "Status update",
                     lambda: start.set_status(gh, status_item, status))
    print(f"reopened issue #{number}" + (f" with Status {status}" if status_item else
                                          "; it is not in the work Project, so its Status is unchanged"))
