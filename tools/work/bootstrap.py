"""Converge a repository's labels and tracking Project to its work.json.

Adds and updates only; never deletes a label, field or Project (README.md).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple
from urllib.parse import quote

from gh import Gh


class BootstrapError(RuntimeError):
    pass


# ---------------------------------------------------------------- pure planning


@dataclass
class OptionPlan:
    changed: bool
    options: List[dict]  # declared order; "id" present when an option is kept
    removed: List[str]


def plan_options(live: List[dict], declared: List[dict], used_option_ids: Set[str]) -> OptionPlan:
    by_name = {option["name"].casefold(): option for option in live}
    options: List[dict] = []
    for want in declared:
        option = {
            "name": want["name"],
            "color": want.get("color", "GRAY"),
            "description": want.get("description", ""),
        }
        existing = by_name.pop(want["name"].casefold(), None)
        if existing is not None:
            option = {"id": existing["id"], **option}
        options.append(option)
    removed = list(by_name.values())
    in_use = [option["name"] for option in removed if option["id"] in used_option_ids]
    if in_use:
        raise BootstrapError(
            "refusing to remove single-select options still used by Project items: " + ", ".join(in_use)
        )
    current = [
        (option["id"], option["name"], option.get("color", ""), option.get("description") or "")
        for option in live
    ]
    wanted = [
        (option.get("id"), option["name"], option["color"], option["description"]) for option in options
    ]
    return OptionPlan(changed=current != wanted, options=options, removed=[option["name"] for option in removed])


def plan_labels(live: List[dict], declared: List[dict]) -> Tuple[List[dict], List[Tuple[str, dict]], List[str]]:
    by_name = {label["name"].casefold(): label for label in live}
    creates: List[dict] = []
    updates: List[Tuple[str, dict]] = []
    for want in declared:
        existing = by_name.pop(want["name"].casefold(), None)
        if existing is None:
            creates.append(want)
        elif (
            existing["name"] != want["name"]
            or existing["color"].lower() != want["color"].lower()
            or (existing.get("description") or "") != want.get("description", "")
        ):
            updates.append((existing["name"], want))
    return creates, updates, sorted(label["name"] for label in by_name.values())


# ------------------------------------------------------------------ live state

_PROJECTS = """
query($login: String!, $cursor: String) {
  repositoryOwner(login: $login) {
    id
    ... on ProjectV2Owner {
      projectsV2(first: 50, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id number title closed public shortDescription url
          repositories(first: 50) { nodes { id } }
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon { id name dataType }
              ... on ProjectV2SingleSelectField { options { id name color description } }
            }
          }
        }
      }
    }
  }
}
"""

_ITEM_OPTIONS = """
query($project: ID!, $field: String!, $cursor: String) {
  node(id: $project) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          fieldValueByName(name: $field) {
            ... on ProjectV2ItemFieldSingleSelectValue { optionId }
          }
        }
      }
    }
  }
}
"""

_TYPES = {"single_select": "SINGLE_SELECT", "number": "NUMBER", "text": "TEXT", "date": "DATE"}


@dataclass
class Action:
    kind: str
    target: str
    detail: Dict[str, Any] = field(default_factory=dict)

    def describe(self) -> str:
        return f"{self.kind} {self.target}"


@dataclass
class Plan:
    actions: List[Action]
    notes: List[str]


class Bootstrap:
    def __init__(self, gh: Gh, root: Path, config: dict) -> None:
        self.gh = gh
        self.root = root
        self.config = config
        repo = json.loads(gh.run("repo", "view", "--json", "id,nameWithOwner,owner"))
        self.repo_id = repo["id"]
        self.repo = repo["nameWithOwner"]
        self.owner = repo["owner"]["login"]

    # Projects belonging to the owner whose title matches the declaration.
    def _projects(self) -> Tuple[str, List[dict]]:
        found: List[dict] = []
        owner_id = ""
        cursor = None
        while True:
            data = self.gh.graphql(_PROJECTS, login=self.owner, cursor=cursor)
            owner = data["repositoryOwner"]
            owner_id = owner["id"]
            page = owner["projectsV2"]
            found += [p for p in page["nodes"] if p["title"] == self.config["project"]["title"]]
            if not page["pageInfo"]["hasNextPage"]:
                return owner_id, found
            cursor = page["pageInfo"]["endCursor"]

    def _used_option_ids(self, project_id: str, field_name: str) -> Set[str]:
        used: Set[str] = set()
        cursor = None
        while True:
            items = self.gh.graphql(_ITEM_OPTIONS, project=project_id, field=field_name, cursor=cursor)["node"]["items"]
            used |= {n["fieldValueByName"]["optionId"] for n in items["nodes"] if n.get("fieldValueByName")}
            if not items["pageInfo"]["hasNextPage"]:
                return used
            cursor = items["pageInfo"]["endCursor"]

    def plan(self) -> Plan:
        actions: List[Action] = []
        notes: List[str] = []

        live_labels = self.gh.rest_pages(f"repos/{self.repo}/labels?per_page=100")
        creates, updates, undeclared = plan_labels(live_labels, self.config["labels"])
        actions += [Action("create-label", want["name"], want) for want in creates]
        actions += [Action("update-label", name, want) for name, want in updates]
        if undeclared:
            notes.append("undeclared labels left in place: " + ", ".join(undeclared))

        declared = self.config["project"]
        owner_id, projects = self._projects()
        if len(projects) > 1:
            raise BootstrapError(
                f"{len(projects)} Projects are titled {declared['title']!r}; rename or close the extras"
            )
        if not projects:
            actions.append(Action("create-project", declared["title"], {"ownerId": owner_id}))
            return Plan(actions, notes)  # fields are planned after the Project exists
        project = projects[0]
        if project["closed"]:
            raise BootstrapError(f"Project {declared['title']!r} is closed; reopen it first")
        settings = {"shortDescription": declared.get("shortDescription", ""), "public": declared.get("public", False)}
        if (project["shortDescription"] or "") != settings["shortDescription"] or project["public"] != settings["public"]:
            actions.append(Action("update-project", project["title"], {"projectId": project["id"], **settings}))
        if self.repo_id not in {r["id"] for r in project["repositories"]["nodes"]}:
            actions.append(Action("link-repository", self.repo, {"projectId": project["id"]}))

        live_fields = {f["name"].casefold(): f for f in project["fields"]["nodes"] if f}
        for want in declared["fields"]:
            data_type = _TYPES[want["type"]]
            existing = live_fields.get(want["name"].casefold())
            if existing is None:
                actions.append(Action("create-field", want["name"], {"projectId": project["id"], "field": want}))
                continue
            if existing["dataType"] != data_type:
                raise BootstrapError(
                    f"Project field {existing['name']!r} is {existing['dataType']}, declared {data_type}; "
                    "refusing to delete a field and its values"
                )
            if data_type == "SINGLE_SELECT":
                live_options = existing["options"]
                declared_names = {o["name"].casefold() for o in want["options"]}
                needs_usage = any(o["name"].casefold() not in declared_names for o in live_options)
                used = self._used_option_ids(project["id"], existing["name"]) if needs_usage else set()
                option_plan = plan_options(live_options, want["options"], used)
                if option_plan.changed or existing["name"] != want["name"]:
                    actions.append(
                        Action(
                            "update-field",
                            want["name"],
                            {"fieldId": existing["id"], "name": want["name"], "options": option_plan.options,
                             "removedUnusedOptions": option_plan.removed},
                        )
                    )

        live_rulesets = {r["name"] for r in self.gh.rest_pages(f"repos/{self.repo}/rulesets?per_page=100")}
        for relative in self.config.get("rulesets", []):
            name = json.loads((self.root / relative).read_text())["name"]
            if name not in live_rulesets:
                notes.append(
                    f"ruleset {name!r} is not applied (maintainer action, not bootstrap): "
                    f"gh api -X POST repos/{self.repo}/rulesets --input {relative}"
                )
        notes.append(f"Project: {project['url']}")
        return Plan(actions, notes)

    def apply(self, action: Action) -> None:
        d = action.detail
        if action.kind == "create-label":
            self.gh.rest("POST", f"repos/{self.repo}/labels", d)
        elif action.kind == "update-label":
            body = {"new_name": d["name"], "color": d["color"], "description": d.get("description", "")}
            self.gh.rest("PATCH", f"repos/{self.repo}/labels/{quote(action.target, safe='')}", body)
        elif action.kind == "create-project":
            self.gh.graphql(
                "mutation($owner: ID!, $title: String!) { createProjectV2(input: {ownerId: $owner, title: $title}) "
                "{ projectV2 { id } } }",
                owner=d["ownerId"], title=action.target,
            )
        elif action.kind == "update-project":
            self.gh.graphql(
                "mutation($id: ID!, $desc: String!, $public: Boolean!) { updateProjectV2(input: "
                "{projectId: $id, shortDescription: $desc, public: $public}) { projectV2 { id } } }",
                id=d["projectId"], desc=d["shortDescription"], public=d["public"],
            )
        elif action.kind == "link-repository":
            self.gh.graphql(
                "mutation($project: ID!, $repo: ID!) { linkProjectV2ToRepository(input: "
                "{projectId: $project, repositoryId: $repo}) { repository { id } } }",
                project=d["projectId"], repo=self.repo_id,
            )
        elif action.kind == "create-field":
            want = d["field"]
            variables: Dict[str, Any] = {"project": d["projectId"], "name": want["name"], "type": _TYPES[want["type"]]}
            if want["type"] == "single_select":
                variables["options"] = [
                    {"name": o["name"], "color": o.get("color", "GRAY"), "description": o.get("description", "")}
                    for o in want["options"]
                ]
                query = (
                    "mutation($project: ID!, $name: String!, $type: ProjectV2CustomFieldType!, "
                    "$options: [ProjectV2SingleSelectFieldOptionInput!]) { createProjectV2Field(input: "
                    "{projectId: $project, name: $name, dataType: $type, singleSelectOptions: $options}) "
                    "{ projectV2Field { ... on ProjectV2FieldCommon { id } } } }"
                )
            else:
                query = (
                    "mutation($project: ID!, $name: String!, $type: ProjectV2CustomFieldType!) { "
                    "createProjectV2Field(input: {projectId: $project, name: $name, dataType: $type}) "
                    "{ projectV2Field { ... on ProjectV2FieldCommon { id } } } }"
                )
            self.gh.graphql(query, **variables)
        elif action.kind == "update-field":
            self.gh.graphql(
                "mutation($field: ID!, $name: String!, $options: [ProjectV2SingleSelectFieldOptionInput!]) { "
                "updateProjectV2Field(input: {fieldId: $field, name: $name, singleSelectOptions: $options}) "
                "{ projectV2Field { ... on ProjectV2FieldCommon { id } } } }",
                field=d["fieldId"], name=d["name"], options=d["options"],
            )
        else:
            raise BootstrapError(f"unknown action {action.kind}")


def run(gh: Gh, root: Path, config: dict, apply: bool, report: Optional[Path]) -> int:
    bootstrap = Bootstrap(gh, root, config)
    applied: List[dict] = []
    plan = bootstrap.plan()
    # A new Project needs a second pass for its fields; any further pending
    # action after that means the declaration cannot converge.
    for _ in range(3 if apply else 0):
        if not plan.actions:
            break
        for action in plan.actions:
            print(f"apply: {action.describe()}")
            bootstrap.apply(action)
            applied.append({"kind": action.kind, "target": action.target})
        plan = bootstrap.plan()
    for action in plan.actions:
        print(f"pending: {action.describe()}")
    for note in plan.notes:
        print(f"note: {note}")
    if report is not None:
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(json.dumps({
            "repository": bootstrap.repo,
            "applied": applied,
            "pending": [{"kind": a.kind, "target": a.target, "detail": a.detail} for a in plan.actions],
            "notes": plan.notes,
        }, indent=2) + "\n")
    if plan.actions:
        if apply:
            raise BootstrapError("GitHub did not converge to the declaration after applying")
        return 2
    print("in sync" if not applied else f"in sync after {len(applied)} change(s)")
    return 0
