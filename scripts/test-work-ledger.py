#!/usr/bin/env python3
"""Exercise `scripts/tron work ledger` through the real CLI, Git and a process-level gh fixture.

1. Unreadable GitHub evidence exits 3 and never reads as clean; `--module` needs no GitHub.
2. `--create` files a labeled, parented module issue with a full unreviewed checklist and is
   idempotent: a re-run after a failed parent link finishes it without a duplicate.
3. The report finds stale, misplaced, doubly listed, malformed, unchecklisted, orphan,
   duplicate and unparented entries, ignores retired duplicates, and rolls up states.
4. `--sync` keeps states, follows renames since the recorded revision (also across modules),
   drops deleted paths visibly, adds new files as unreviewed, writes nothing when unchanged,
   and refuses a dirty index, ownership violations or an unfollowable history.

The last fixture state and outputs are kept in `test-results/work-ledger/`.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "test-results" / "work-ledger"
COPIED = ["scripts/tron", "scripts/personal-info-guard.sh", ".github/work.json", "tools/ownership/ownership.py",
          *(f"tools/work/{p.name}" for p in (ROOT / "tools/work").glob("*.py"))]
AREA, PHASE = 10, 2


def fixture_gh() -> None:
    path = Path(os.environ["LEDGER_FIXTURE"])
    state = json.loads(path.read_text())
    args = sys.argv[1:]
    issues = state["issues"]
    out = None

    def node(number: int) -> dict:
        issue = issues[str(number)]
        parent = issue.get("parent")
        return {"number": number, "state": issue["state"], "stateReason": issue.get("reason"),
                "title": issue["title"], "body": issue["body"],
                "parent": parent and {"number": parent, "title": issues[str(parent)]["title"],
                                      "parent": issues[str(parent)].get("parent") and
                                      {"number": issues[str(parent)]["parent"], "title": "Phase"}}}

    def fail(message: str) -> None:
        path.write_text(json.dumps(state))
        print(message, file=sys.stderr)
        sys.exit(1)

    if args[:2] == ["repo", "view"]:
        out = {"id": "repo", "nameWithOwner": "fixture/project", "owner": {"login": "fixture"}}
    elif args[:2] == ["api", "graphql"]:
        request = json.load(sys.stdin)
        query, variables = request["query"], request["variables"]
        if "issues(first: 50" in query:
            if state.get("unavailable"):
                fail("HTTP 502: fixture GitHub unavailable")
            numbers = sorted(int(n) for n, i in issues.items() if "restructure" in i["labels"])
            start = int(variables.get("cursor") or 0)
            page = numbers[start:start + 2]  # two per page exercises pagination
            more = start + 2 < len(numbers)
            out = {"data": {"repository": {"issues": {
                "pageInfo": {"hasNextPage": more, "endCursor": str(start + 2) if more else None},
                "nodes": [node(n) for n in page]}}}}
        elif "repositoryOwner" in query:
            options = lambda names: [{"id": n.lower(), "name": n} for n in names]  # noqa: E731
            out = {"data": {"repositoryOwner": {"id": "owner", "projectsV2": {
                "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [{
                    "id": "project", "title": "Tron", "repositories": {"nodes": [{"id": "repo"}]},
                    "fields": {"nodes": [
                        {"id": "status", "name": "Status", "options": options(["Ready", "In progress", "Blocked", "Done"])},
                        {"id": "priority", "name": "Priority", "options": options(["P0", "P1", "P2", "P3"])}]}}]}}}}
        elif "projectItems" in query:
            number = variables["issue"].split("-")[1]
            items = [{"id": "item", "project": {"id": "project", "title": "Tron"}}] if issues[number].get("project", True) else []
            out = {"data": {"node": {"projectItems": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                                                      "nodes": items}}}}
        elif "addProjectV2ItemById" in query:
            if state.pop("fail_project_once", False):
                fail("HTTP 502: fixture Project add failed")
            issues[variables["content"].split("-")[1]]["project"] = True
            state["writes"].append("project")
            out = {"data": {"addProjectV2ItemById": {"item": {"id": "item"}}}}
        elif "updateProjectV2ItemFieldValue" in query:
            out = {"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "item"}}}}
        elif "subIssues(first" in query:
            epic = int(variables["issue"].split("-")[1])
            out = {"data": {"node": {"subIssues": {"nodes": [{"id": f"node-{n}"} for n, i in issues.items()
                                                             if i.get("parent") == epic]},
                                     "blockedBy": {"nodes": []}}}}
        elif "addSubIssue" in query:
            if state.pop("fail_parent_once", False):
                fail("HTTP 502: fixture parent link failed")
            issues[variables["child"].split("-")[1]]["parent"] = int(variables["epic"].split("-")[1])
            state["writes"].append("parent")
            out = {"data": {"addSubIssue": {"issue": {"id": variables["epic"]}}}}
        else:
            raise AssertionError(f"unexpected graphql: {query[:80]}")
    elif args[:3] == ["api", "-X", "GET"]:
        number = int(args[3].rsplit("/", 1)[-1])
        issue = issues[str(number)]
        out = {"number": number, "node_id": f"node-{number}", "state": issue["state"].lower(), "body": issue["body"],
               "labels": [{"name": label} for label in issue["labels"]]}
    elif args[:3] == ["api", "-X", "POST"] and args[3].endswith("/issues"):
        created = json.load(sys.stdin)
        number = max(int(n) for n in issues) + 1
        issues[str(number)] = {"state": "OPEN", "title": created["title"], "body": created["body"],
                               "labels": created["labels"], "project": False}
        state["writes"].append("create")
        out = {"number": number, "node_id": f"node-{number}"}
    elif args[:3] == ["api", "-X", "PATCH"]:
        number = args[3].rsplit("/", 1)[-1]
        issues[number].update(json.load(sys.stdin))
        state["writes"].append(f"edit {number}")
        out = {"number": int(number)}
    else:
        raise AssertionError(f"unexpected gh invocation: {args}")
    path.write_text(json.dumps(state))
    print(json.dumps(out))


class Fixture:
    def __init__(self, base: Path):
        self.repo = base / "repo"
        self.state_path = base / "github.json"
        home = base / "home"
        home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base),
                    "WORK_GH": str(Path(__file__).resolve()), "LEDGER_FIXTURE": str(self.state_path),
                    "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        for relative in COPIED:
            (self.repo / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.repo / relative)
        self.write("tooling.module.json", {"layer": "L5", "owns": ["scripts/**", "tools/**", ".github/**",
                                                                    "tooling.module.json"]})
        self.write("packages/gateway/src/a/a.module.json", {"layer": "L3", "owns": ["**"]})
        self.write("packages/gateway/src/b/b.module.json", {"layer": "L3", "owns": ["**"]})
        for name in ("a/one.ts", "a/two.ts", "a/three.ts", "b/four.ts"):
            self.write(f"packages/gateway/src/{name}", "".join(f"{name} line {i}\n" for i in range(30)))
        self.commit("fixture")
        self.save({"writes": [], "issues": {
            str(PHASE): {"state": "OPEN", "title": "Phase", "body": "phase", "labels": ["epic", "restructure"]},
            str(AREA): {"state": "OPEN", "title": "Area: app", "body": "area", "labels": ["epic", "restructure"],
                        "parent": PHASE}}})

    def write(self, relative: str, content) -> None:
        target = self.repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content if isinstance(content, str) else json.dumps(content))

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def load(self) -> dict:
        return json.loads(self.state_path.read_text())

    def save(self, state: dict) -> None:
        self.state_path.write_text(json.dumps(state))

    def update(self, **changes) -> None:
        state = self.load()
        state.update(changes)
        self.save(state)

    def issue(self, number: int, body: str, parent=AREA, labels=("restructure", "kind:maintenance"), **extra) -> None:
        state = self.load()
        state["issues"][str(number)] = {"state": "OPEN", "title": f"Module {number}", "body": body,
                                        "labels": list(labels), "parent": parent, **extra}
        self.save(state)

    def ledger(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.repo / "scripts/tron"), "work", "ledger", *args], cwd=self.repo,
                                env=self.env, capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron work ledger {' '.join(args)}\nexit {result.returncode}\n"
                      f"{result.stdout}{result.stderr}\n")
        shutil.copy2(self.state_path, ARTIFACTS / "github.json")
        return result


def TOOLING_PATHS(fixture) -> list:
    return [p for p in fixture.git("ls-files").split() if not p.startswith("packages/")]


def checklist(revision: str, *entries: str) -> str:
    lines = "\n".join(f"- [{'x' if e.endswith('done') else ' '}] `{e.split(' — ')[0]}` — {e.split(' — ')[1]}"
                      for e in entries)
    return (f"Parent: #{AREA}. Module: `{{id}}`\n\n## Files (ledger)\nLedger sync: `{revision}` (x)\n\n{lines}\n\n"
            "## Slices\nkept\n")


class LedgerCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-work-ledger-")
        self.f = Fixture(Path(self.temp.name))
        self.head = self.f.git("rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ok(self, *args: str, code: int = 0) -> str:
        result = self.f.ledger(*args)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout


class UnavailableTests(LedgerCase):
    def test_unreadable_github_is_exit_3_never_clean_and_module_listing_is_local(self) -> None:
        self.f.update(unavailable=True)
        out = self.ok(code=3)
        self.assertIn("GitHub unavailable", out)
        self.assertIn("checklists NOT checked; ownership clean", out)
        self.assertNotIn("checklisted exactly once", out)
        self.assertEqual(self.ok("--module", "gateway/a").split(), [
            "packages/gateway/src/a/a.module.json", "packages/gateway/src/a/one.ts",
            "packages/gateway/src/a/three.ts", "packages/gateway/src/a/two.ts"])


class CreateTests(LedgerCase):
    def test_create_files_a_full_unreviewed_checklist_and_is_idempotent_after_a_failed_link(self) -> None:
        self.f.update(fail_parent_once=True)
        failed = self.f.ledger("--create", "gateway/a", "--epic", str(AREA))
        self.assertEqual(failed.returncode, 1)
        self.assertIn("exists but its parent link failed or is uncertain", failed.stderr)
        self.assertIn("exists", self.ok("--create", "gateway/a", "--epic", str(AREA)))
        self.f.update(fail_project_once=True)
        partial = self.f.ledger("--create", "gateway/b", "--epic", str(AREA))
        self.assertEqual(partial.returncode, 1)
        self.assertIn("Project membership is incomplete", partial.stderr)
        self.ok("--create", "gateway/b", "--epic", str(AREA))  # repairs membership, then links
        moved = self.f.ledger("--create", "gateway/b", "--epic", str(PHASE))
        self.assertIn("is already under #10; move it explicitly", moved.stderr)
        state = self.f.load()
        self.assertEqual(state["writes"].count("create"), 2, state["writes"])
        self.assertTrue(all(state["issues"][n].get("project") for n in ("11", "12")))
        created = state["issues"]["11"]
        self.assertEqual((created["title"], created["parent"]), ("Module: gateway/a", AREA))
        self.assertEqual(sorted(created["labels"]), ["area:gateway", "kind:maintenance", "restructure"])
        self.assertIn(f"Ledger sync: `{self.head}`", created["body"])
        self.assertIn("- [ ] `packages/gateway/src/a/two.ts` — unreviewed", created["body"])
        # The tooling module has no issue yet; the app modules are fully checklisted and rolled up.
        out = self.ok(code=1)
        self.assertEqual([line for line in out.splitlines() if line.startswith(("unissued", "unchecklisted"))],
                         [f"unissued module: repo/tooling ({len(TOOLING_PATHS(self.f))} paths, tooling.module.json)"])
        self.assertIn(f"area #{AREA}: 2 modules, 6/6 checklisted (unreviewed 6)", out)
        self.assertIn(f"phase #{PHASE}: 2 modules, 6/6 checklisted (unreviewed 6)", out)


class ReportTests(LedgerCase):
    def test_report_finds_each_checklist_violation_and_ignores_retired_duplicates(self) -> None:
        f, h = self.f, self.head
        f.issue(20, checklist(h, "packages/gateway/src/a/one.ts — keep", "packages/gateway/src/a/one.ts — keep",
                              "packages/gateway/src/a/gone.ts — keep", "packages/gateway/src/b/four.ts — done",
                              "packages/gateway/src/a/a.module.json — done").replace("{id}", "gateway/a")
                + "\n## Files again\n- [ ] `packages/gateway/src/a/two.ts` — maybe\n- broken line\n")
        f.issue(21, checklist(h, "packages/gateway/src/b/four.ts — simplify", "packages/gateway/src/b/b.module.json — keep")
                .replace("{id}", "gateway/b"), parent=None)
        f.issue(22, checklist(h, "tooling.module.json — keep").replace("{id}", "repo/tooling"))
        f.issue(23, checklist(h).replace("{id}", "repo/tooling"), state="CLOSED", reason="DUPLICATE")
        f.issue(24, checklist(h).replace("{id}", "gateway/gone"))
        f.issue(25, checklist(h).replace("{id}", "gateway/gone-done"), state="CLOSED", reason="COMPLETED")
        f.issue(26, "Module: `gateway/b` copy\n## Files\n")
        out = self.ok(code=1).splitlines()
        violations = [line for line in out if not line.startswith(("phase ", "area ", "epic:", "ledger:"))]
        self.assertEqual(violations, sorted([
            "#20 (gateway/a): line 15 starts a second Files section",
            "#20 (gateway/a): line 16 has unknown state 'maybe'",
            "#20 (gateway/a): line 17 is not '- [ ] `path` — state'",
            "#20 (gateway/a): lists packages/gateway/src/a/gone.ts, which is not a tracked file",
            "#20 (gateway/a): lists packages/gateway/src/a/one.ts more than once",
            "#20 (gateway/a): lists packages/gateway/src/b/four.ts, owned by gateway/b",
            "#21 (gateway/b): has no Area epic parent",
            "#24 (gateway/gone): no gateway/gone manifest exists",
            "checklisted more than once: packages/gateway/src/b/four.ts in #20, #21",
            "duplicate module issues for gateway/b: #21, #26",
            "unchecklisted: packages/gateway/src/a/three.ts (missing from #20 (gateway/a))",
            "unchecklisted: packages/gateway/src/a/two.ts (missing from #20 (gateway/a))",
            "unchecklisted: packages/gateway/src/b/b.module.json (missing from #26 (gateway/b))",
            "unchecklisted: packages/gateway/src/b/four.ts (missing from #26 (gateway/b))",
        ] + [f"unchecklisted: {p} (missing from #22 (repo/tooling))" for p in TOOLING_PATHS(f)
               if p != "tooling.module.json"]))
        self.assertIn(f"epic: 3 modules, 5/{len(f.git('ls-files').split())} checklisted (keep 3, simplify 1, done 1)", out)
        self.assertIn("area (no parent): 1 modules, 2/2 checklisted (keep 1, simplify 1)", out)


class SyncTests(LedgerCase):
    def test_sync_keeps_states_across_renames_and_modules_and_never_invents_audit(self) -> None:
        f, h = self.f, self.head
        f.issue(30, checklist(h, "packages/gateway/src/a/a.module.json — keep", "packages/gateway/src/a/one.ts — done",
                              "packages/gateway/src/a/two.ts — move→packages/gateway/src/b/", "packages/gateway/src/a/three.ts — simplify")
                .replace("{id}", "gateway/a"))
        f.issue(31, checklist(h, "packages/gateway/src/b/b.module.json — keep", "packages/gateway/src/b/four.ts — delete")
                .replace("{id}", "gateway/b"))
        f.git("mv", "packages/gateway/src/a/one.ts", "packages/gateway/src/a/uno.ts")      # rename inside a module
        f.git("mv", "packages/gateway/src/a/two.ts", "packages/gateway/src/b/two.ts")      # move to another module
        f.git("rm", "-q", "packages/gateway/src/b/four.ts")                             # delete
        f.write("packages/gateway/src/b/five.ts", "new\n")                              # add
        head = f.commit("move files")
        early = f.ledger("--sync", "30")
        self.assertEqual(early.returncode, 1)
        self.assertIn("#30 would lose audit state: sync #31 (gateway/b) first: it does not list "
                      "packages/gateway/src/b/two.ts yet", early.stderr)
        out_b = self.ok("--sync", "31")
        out_a = self.ok("--sync", "30")
        self.assertIn("renamed packages/gateway/src/a/one.ts → packages/gateway/src/a/uno.ts — done", out_a)
        self.assertIn("dropped packages/gateway/src/a/two.ts — move→packages/gateway/src/b/ "
                      "(now packages/gateway/src/b/two.ts in #31 (gateway/b))", out_a)
        self.assertIn("renamed packages/gateway/src/a/two.ts → packages/gateway/src/b/two.ts — move→packages/gateway/src/b/ "
                      "(from another module issue)", out_b)
        self.assertIn("dropped packages/gateway/src/b/four.ts — delete (deleted)", out_b)
        self.assertIn("added packages/gateway/src/b/five.ts — unreviewed", out_b)
        issues = f.load()["issues"]
        self.assertIn(f"Ledger sync: `{head}`", issues["30"]["body"])
        self.assertIn("- [x] `packages/gateway/src/a/uno.ts` — done", issues["30"]["body"])
        self.assertIn("- [ ] `packages/gateway/src/a/three.ts` — simplify", issues["30"]["body"])
        self.assertIn("## Slices\nkept", issues["30"]["body"])
        self.assertIn("- [ ] `packages/gateway/src/b/two.ts` — move→packages/gateway/src/b/", issues["31"]["body"])
        self.assertIn("- [ ] `packages/gateway/src/b/five.ts` — unreviewed", issues["31"]["body"])
        self.assertNotIn("four.ts", issues["31"]["body"])
        writes = len(f.load()["writes"])
        self.assertIn("unchanged", self.ok("--sync", "30"))
        self.assertEqual(len(f.load()["writes"]), writes)

    def test_unpaired_vanished_or_replaced_state_refuses_and_new_files_never_inherit(self) -> None:
        f, h = self.f, self.head
        f.issue(50, checklist(h, "packages/gateway/src/a/a.module.json — keep", "packages/gateway/src/a/one.ts — done",
                              "packages/gateway/src/a/two.ts — keep", "packages/gateway/src/a/three.ts — simplify",
                              "packages/gateway/src/b/six.ts — done").replace("{id}", "gateway/a"))
        f.issue(51, checklist(h, "packages/gateway/src/b/b.module.json — keep", "packages/gateway/src/b/four.ts — keep")
                .replace("{id}", "gateway/b"))
        f.git("rm", "-q", "packages/gateway/src/a/three.ts")
        f.git("mv", "packages/gateway/src/a/one.ts", "packages/gateway/src/a/three.ts")  # replaces three.ts
        f.git("mv", "packages/gateway/src/a/two.ts", "packages/gateway/src/a/deux.ts")   # move, then rewrite
        f.write("packages/gateway/src/a/deux.ts", "entirely\ndifferent\ncontent\n")
        f.write("packages/gateway/src/b/six.ts", "brand new file at a stale listed path\n")
        f.write("packages/gateway/src/a/a.module.json", {"layer": "L3", "owns": ["*.ts"]})  # unstaged: ignored
        f.git("add", "packages/gateway/src")
        f.git("reset", "-q", "packages/gateway/src/a/a.module.json")
        f.git("commit", "-q", "-m", "replace and rewrite")
        out_b = self.ok("--sync", "51")
        self.assertIn("added packages/gateway/src/b/six.ts — unreviewed", out_b)  # not inherited from #50's stale entry
        refused = f.ledger("--sync", "50")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("packages/gateway/src/a/three.ts (simplify) had its content replaced", refused.stderr)
        self.assertIn("packages/gateway/src/a/two.ts (keep) vanished without a rename Git can pair", refused.stderr)
        self.assertEqual(f.load()["writes"], ["edit 51"])
        # The scoper records the outcome in the issue; sync then proceeds without inventing anything.
        state = f.load()
        body = state["issues"]["50"]["body"]
        state["issues"]["50"]["body"] = (body.replace("a/three.ts` — simplify", "a/three.ts` — delete")
                                         .replace("a/two.ts` — keep", "a/two.ts` — delete"))
        f.save(state)
        out = self.ok("--sync", "50")
        self.assertIn("renamed packages/gateway/src/a/one.ts → packages/gateway/src/a/three.ts — done", out)
        self.assertIn("dropped packages/gateway/src/a/three.ts — delete (content replaced)", out)
        self.assertIn("added packages/gateway/src/a/deux.ts — unreviewed", out)
        body = f.load()["issues"]["50"]["body"]
        self.assertIn("- [x] `packages/gateway/src/a/three.ts` — done", body)
        self.assertIn("`packages/gateway/src/a/a.module.json` — keep", body)  # committed manifest still owns it
        self.assertIn("dropped packages/gateway/src/b/six.ts — done (now packages/gateway/src/b/six.ts in #51 "
                      "(gateway/b))", out)

    def test_sync_refuses_dirty_index_ownership_violations_and_unfollowable_history(self) -> None:
        f, h = self.f, self.head
        f.issue(40, checklist("0" * 40, "packages/gateway/src/a/gone.ts — keep").replace("{id}", "gateway/a"))
        refused = f.ledger("--sync", "40")
        self.assertEqual(refused.returncode, 1)
        self.assertIn("no reachable sync revision, so renames cannot be followed", refused.stderr)
        f.write("packages/gateway/src/a/new.ts", "x\n")
        f.git("add", "packages/gateway/src/a/new.ts")
        self.assertIn("the index differs from HEAD", f.ledger("--sync", "40").stderr)
        f.write("packages/gateway/src/stray.ts", "x\n")
        f.commit("unowned file")
        self.assertIn("ownership has 1 violation(s)", f.ledger("--sync", "40").stderr)
        self.assertEqual(f.load()["writes"], [])


if __name__ == "__main__":
    if os.environ.get("LEDGER_FIXTURE"):
        fixture_gh()
    else:
        unittest.main(verbosity=2)
