"""CI evidence boundary regressions: real Git + CLI-shaped GitHub replies.

Failure modes: merged failures vanish; stale/fork heads contaminate evidence;
missing/cancelled/pending/unavailable evidence appears green; job pagination
loses a failure; hostile branch text becomes markup.
"""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from dashboard import run
from gh import Gh
from test_dashboard import CONFIG, FAKE_GH, git, pull

REST = '''
if sys.argv[1:4] == ["api", "-X", "GET"]:
    from urllib.parse import urlparse, parse_qs
    path = sys.argv[4]
    query = parse_qs(urlparse(path).query)
    if fixture.get("unavailable"):
        print("Actions API unavailable", file=sys.stderr)
        sys.exit(1)
    if "/jobs?" in path:
        jobs = fixture.get("jobs", [])
        page = int(query.get("page", ["1"])[0])
        print(json.dumps({"total_count": len(jobs), "jobs": jobs[(page-1)*100:page*100]}))
    else:
        scope = "pr" if query.get("event") == ["pull_request"] else "main"
        print(json.dumps({"workflow_runs": fixture.get(scope, [])}))
    sys.exit(0)
'''
FAKE = FAKE_GH.replace('query = json.load(sys.stdin)["query"]', REST + '\nquery = json.load(sys.stdin)["query"]')
FAKE = FAKE.replace('"pullRequests": page([])', '"pullRequests": page(fixture.get("pulls", []))')


def workflow(sha="b" * 40, branch="main", event="push", status="completed", conclusion="failure"):
    return {"id": 100, "head_sha": sha, "head_branch": branch, "event": event,
            "status": status, "conclusion": conclusion,
            "html_url": "https://github.com/owner/repo/actions/runs/100",
            "head_repository": {"full_name": "owner/repo"}}


def job(name, conclusion, status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion,
            "html_url": "https://github.com/owner/repo/actions/runs/100/job/1"}


class CIDashboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        remote = self.root / "remote.git"
        git(self.root, "init", "-q", "--bare", "-b", "main", str(remote))
        self.repo = self.root / "repo"
        git(self.root, "clone", "-q", str(remote), str(self.repo))
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")
        git(self.repo, "push", "-q", "origin", "HEAD:main")
        self.script = self.root / "gh"
        self.script.write_text(f"#!{sys.executable}\n" + FAKE)
        self.script.chmod(0o755)
        self.config = copy.deepcopy(CONFIG)
        self.config["dashboard"].update(ciWorkflow="ci.yml", advisoryJobs=["gateway", "ios", "mac", "pi-sdk-e2e"])

    def dashboard(self, **fixture):
        fixture_path = self.root / "fixture.json"
        fixture_path.write_text(json.dumps({"items": [], "states": {}, **fixture}))
        out = self.root / "dashboard.json"
        page = self.root / "dashboard.html"
        text = io.StringIO()
        with mock.patch.dict(os.environ, WORK_GH=str(self.script), FAKE_GH_FIXTURE=str(fixture_path)), contextlib.redirect_stdout(text):
            run(Gh(self.repo), self.repo, self.config, page, out)
        return json.loads(out.read_text()), text.getvalue(), page.read_text()

    def test_merged_main_failure_survives_without_an_open_pull_and_paginates_jobs(self):
        jobs = [job("policy", "success")] * 100 + [job("mac", "failure"), job("ios", "skipped"),
                                                    job("gateway", "success"), job("pi-sdk-e2e", "cancelled")]
        model, text, page = self.dashboard(main=[workflow()], jobs=jobs)
        row = model["ci"][0]
        self.assertEqual(row["jobs"]["mac"]["state"], "failure")
        self.assertEqual(row["jobs"]["ios"]["state"], "skipped")
        self.assertIn("mac=failure", text)
        self.assertIn("pi-sdk-e2e=cancelled", text)
        self.assertIn("https://github.com/owner/repo/actions/runs/100", page)
        health = page.split('id="health"', 1)[1].split('id="', 1)[0]
        self.assertIn("mac=failure", health)

    def test_stale_or_foreign_run_cannot_represent_current_pr_head(self):
        pr = pull(8, "feat/7-work")
        for candidate in [workflow(branch="feat/7-work", event="pull_request"),
                          {**workflow(sha="a" * 40, branch="feat/7-work", event="pull_request"),
                           "head_repository": {"full_name": "stranger/fork"}}]:
            model, _, _ = self.dashboard(pulls=[pr], pr=[candidate])
            self.assertEqual(model["ci"][1]["state"], "missing")
        model, _, _ = self.dashboard(pulls=[pull(9, "feat/7-work", fork=True)])
        self.assertEqual(len(model["ci"]), 1)

    def test_pending_cancelled_missing_and_api_failure_are_not_healthy(self):
        for fixture, expected in [({}, "missing"), ({"unavailable": True}, "unavailable"),
                                  ({"main": [workflow(status="queued", conclusion=None)]}, "pending"),
                                  ({"main": [workflow(conclusion="cancelled")]}, "cancelled")]:
            model, text, _ = self.dashboard(**fixture)
            self.assertEqual(model["ci"][0]["state"], expected)
            self.assertIn(expected, text)
        model, _, _ = self.dashboard(main=[workflow(conclusion="success")])
        self.assertEqual(model["ci"][0]["jobs"]["mac"]["state"], "missing")

    def test_exact_pr_head_and_hostile_branch_are_rendered_safely(self):
        branch = "feat/<script>"
        model, text, page = self.dashboard(pulls=[pull(8, branch)],
            pr=[workflow(sha="a" * 40, branch=branch, event="pull_request")], jobs=[job("mac", "failure")])
        self.assertEqual(model["ci"][1]["sha"], "a" * 40)
        self.assertIn("PR #8", text)
        self.assertIn("&lt;script&gt;", page)
        self.assertNotIn("<script>", page)


if __name__ == "__main__":
    unittest.main()
