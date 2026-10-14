#!/usr/bin/env python3
"""`work bootstrap` drift journeys through the real CLI and a process-level gh fixture (#993).

GitHub holds labels, a Project field and Status options that `.github/work.json` no longer
declares. Plain bootstrap reports each as drift and exits 2; `--apply --prune` deletes only
labels no open issue uses, unused options and undeclared fields (with their values), and keeps
reporting labels and options still in use.
Evidence: test-results/work-bootstrap.json.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fixture_gh() -> None:
    path = Path(os.environ["WORK_BOOTSTRAP_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    page = {"hasNextPage": False, "endCursor": None}
    response = None
    if args[:2] == ["repo", "view"]:
        response = {"id": "repo", "nameWithOwner": "fixture/project", "owner": {"login": "fixture"}}
    elif args[:3] == ["api", "--paginate", "--slurp"]:
        response = [state["labels"]] if "/labels" in args[3] else [[]]  # labels, then rulesets
    elif args[:3] == ["api", "-X", "DELETE"]:
        name = args[3].rsplit("/", 1)[1]
        state["labels"] = [label for label in state["labels"] if label["name"] != name]
        state["writes"].append(f"delete-label {name}")
    elif args[:2] == ["api", "graphql"]:
        request = json.load(sys.stdin)
        query, variables = request["query"], request["variables"]
        project = state["project"]
        if "deleteProjectV2Field" in query:
            project["fields"] = [f for f in project["fields"] if f["id"] != variables["field"]]
            state["writes"].append(f"delete-field {variables['field']}")
            response = {"data": {"deleteProjectV2Field": {"projectV2Field": {"id": variables["field"]}}}}
        elif "updateProjectV2Field" in query:
            field = next(f for f in project["fields"] if f["id"] == variables["field"])
            field["options"] = [{"id": o.get("id") or f"new-{o['name']}", "name": o["name"], "color": o["color"],
                                 "description": o["description"]} for o in variables["options"]]
            state["writes"].append(f"update-field {field['name']}: " + ",".join(o["name"] for o in field["options"]))
            response = {"data": {"updateProjectV2Field": {"projectV2Field": {"id": field["id"]}}}}
        elif "repositoryOwner" in query:
            response = {"data": {"repositoryOwner": {"id": "owner", "projectsV2": {"pageInfo": page, "nodes": [{
                "id": "project", "number": 1, "title": "Tron", "closed": False, "public": False,
                "shortDescription": project["shortDescription"], "url": "https://example.invalid/project",
                "repositories": {"nodes": [{"id": "repo"}]}, "fields": {"nodes": project["fields"]}}]}}}}
        elif "issues(states: OPEN" in query:
            holders = state["open_label_holders"].get(variables["label"], [])
            response = {"data": {"repository": {"issues": {"totalCount": len(holders),
                                                           "nodes": [{"number": n} for n in holders]}}}}
        elif "fieldValueByName" in query:
            values = state["item_values"].get(variables["field"], [])
            response = {"data": {"node": {"items": {"pageInfo": page, "nodes": [{"fieldValueByName": v} for v in values]}}}}
        else:
            raise AssertionError(f"unexpected graphql: {query[:80]}")
    else:
        raise AssertionError(f"unexpected gh invocation: {args}")
    path.write_text(json.dumps(state))
    print(json.dumps(response))


def run() -> None:
    evidence = []
    artifact = ROOT / "test-results" / "work-bootstrap.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / ".github/work.json").read_text())
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-bootstrap-") as temporary:
            root = Path(temporary)
            repo, home, tmp = root / "repo", root / "home", root / "tmp"
            for directory in (repo, home, tmp):
                directory.mkdir()
            env = {**os.environ, "HOME": str(home), "TMPDIR": str(tmp), "WORK_GH": str(Path(__file__).resolve()),
                   "WORK_BOOTSTRAP_FIXTURE": str(root / "github.json"), "PYTHONDONTWRITEBYTECODE": "1",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, env=env, check=True)
            (repo / ".github").mkdir()
            (repo / ".github/work.json").write_text(json.dumps({**config, "rulesets": []}))

            # GitHub as the declaration left it before the cut: every declared item, plus drift.
            labels = [{"name": l["name"], "color": l["color"], "description": l["description"]} for l in config["labels"]]
            labels += [{"name": "task", "color": "1d76db", "description": "old"},
                       {"name": "needs-triage", "color": "ededed", "description": ""}]
            fields = []
            for index, want in enumerate(config["project"]["fields"]):
                live = {"id": f"field-{index}", "name": want["name"], "dataType": want["type"].upper()}
                if want["type"] == "single_select":
                    live["options"] = [{"id": f"{want['name']}-{o['name']}", "name": o["name"], "color": o["color"],
                                        "description": o["description"]} for o in want["options"]]
                fields.append(live)
            status = next(f for f in fields if f["name"] == "Status")
            status["options"] += [{"id": "status-proposed", "name": "Proposed", "color": "GRAY", "description": ""},
                                  {"id": "status-needs-you", "name": "Needs you", "color": "PURPLE", "description": ""}]
            fields += [{"id": "field-rank", "name": "Epic rank", "dataType": "NUMBER"},
                       {"id": "field-title", "name": "Title", "dataType": "TITLE"}]
            state_path = Path(env["WORK_BOOTSTRAP_FIXTURE"])
            state_path.write_text(json.dumps({
                "labels": labels, "writes": [],
                "project": {"shortDescription": config["project"]["shortDescription"], "fields": fields},
                "open_label_holders": {"needs-triage": [515]},
                "item_values": {"Status": [{"optionId": "status-needs-you"}, {"optionId": "Status-Ready"}],
                                "Epic rank": [{"__typename": "ProjectV2ItemFieldNumberValue"}, None]},
            }))

            def bootstrap(name, *extra):
                result = subprocess.run([sys.executable, str(ROOT / "tools/work/cli.py"), "bootstrap", *extra],
                                        cwd=repo, env=env, capture_output=True, text=True, timeout=60)
                evidence.append({"case": name, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
                return result, json.loads(state_path.read_text())

            result, state = bootstrap("plan reports drift and writes nothing")
            assert result.returncode == 2 and not state["writes"], evidence[-1]
            for expected in ("label 'task' is not declared and no open issue uses it",
                             "label 'needs-triage' is not declared; 1 open issue(s) use it (#515)",
                             "Project field 'Epic rank' is not declared; 1 item(s) hold a value",
                             "Status option 'Proposed' is not declared and unused",
                             "Status option 'Needs you' is not declared and Project items still use it"):
                assert expected in result.stdout, (expected, result.stdout)
            assert "Title" not in result.stdout, "a GitHub built-in field was reported as drift"

            result, state = bootstrap("apply without prune deletes nothing", "--apply")
            assert result.returncode == 2 and not state["writes"], evidence[-1]

            result, state = bootstrap("prune deletes only unused drift", "--apply", "--prune")
            assert result.returncode == 2, evidence[-1]
            assert "delete-label task" in state["writes"] and "delete-field field-rank" in state["writes"]
            update = next(w for w in state["writes"] if w.startswith("update-field Status"))
            assert "Proposed" not in update and "Needs you" in update, update
            assert not any("needs-triage" in w for w in state["writes"])
            assert "needs-triage" in result.stdout and "Needs you" in result.stdout

            # Once the last open issue and Project item are migrated, prune converges.
            state["open_label_holders"] = {}
            state["item_values"]["Status"] = [{"optionId": "Status-Ready"}]
            state["writes"] = []
            state_path.write_text(json.dumps(state))
            result, state = bootstrap("prune converges after migration", "--apply", "--prune")
            assert result.returncode == 0 and "in sync" in result.stdout, evidence[-1]
            assert state["writes"][0] == "delete-label needs-triage", state["writes"]
            result, state = bootstrap("in sync plan", )
            assert result.returncode == 0 and "drift" not in result.stdout, evidence[-1]
        print(f"Passed {len(evidence)} bootstrap drift journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_BOOTSTRAP_FIXTURE") and sys.argv[1:2] in (["api"], ["repo"]):
        fixture_gh()
    else:
        run()
