"""Isolated checks for `issues` failure modes 49-52 in README.md.

`work issues` runs as an agent runs it: `cli.py` in a real Git checkout with a
stand-in `gh` executable (`WORK_GH`) that serves GitHub-shaped issue lists and
honors `--state` and `--limit` the way `gh issue list` does.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLI = Path(__file__).resolve().parent / "cli.py"
CONFIG = {"dashboard": {"epicLabel": "epic"}}

FAKE_GH = r'''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
fixture = json.load(open(os.environ["FAKE_GH_FIXTURE"]))
state = args[args.index("--state") + 1]
limit = int(args[args.index("--limit") + 1])
print(json.dumps(fixture[state][:limit]))
'''


def raw(number, state="OPEN", labels=(), body="", title=None, reason=None):
    return {"number": number, "title": title or f"Issue {number}", "body": body, "state": state,
            "stateReason": reason, "closedAt": None if state == "OPEN" else "2026-10-01T00:00:00Z",
            "labels": [{"name": name} for name in labels]}


class IssuesTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".github").mkdir()
        (self.root / ".github" / "work.json").write_text(json.dumps(CONFIG))
        self.gh = self.root / "gh"
        self.gh.write_text(f"#!{sys.executable}\n" + FAKE_GH)
        self.gh.chmod(0o755)
        self.log = self.root / "calls.log"

    def tearDown(self):
        self._tmp.cleanup()

    def work_issues(self, fixture, *args):
        path = self.root / "fixture.json"
        path.write_text(json.dumps(fixture))
        env = {**os.environ, "WORK_GH": str(self.gh), "FAKE_GH_FIXTURE": str(path), "FAKE_GH_LOG": str(self.log)}
        return subprocess.run([sys.executable, str(CLI), "issues", *args], cwd=self.root, env=env,
                              capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_49_an_open_list_at_the_limit_is_refused_not_truncated(self):
        result = self.work_issues({"open": [raw(n) for n in range(1, 502)], "closed": []})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("more than 500 open issues", result.stderr)
        exact = self.work_issues({"open": [raw(n) for n in range(1, 501)], "closed": []})
        self.assertEqual(exact.returncode, 0, exact.stderr)
        self.assertEqual(json.loads(exact.stdout)["open"], 500)

    def test_50_closed_issues_only_on_request_and_marked_closed(self):
        fixture = {"open": [raw(1, labels=["epic"])],
                   "closed": [raw(n, "CLOSED", reason="COMPLETED") for n in range(2, 12)]}
        default = self.work_issues(fixture)
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual([i["number"] for i in json.loads(default.stdout)["issues"]], [1])
        self.assertFalse(any("closed" in call for call in self.calls()), "no closed-issue query by default")
        with_closed = self.work_issues(fixture, "--closed", "--closed-limit", "3")
        corpus = json.loads(with_closed.stdout)
        self.assertEqual([(i["number"], i["state"], i["stateReason"]) for i in corpus["issues"]],
                         [(1, "open", None), (2, "closed", "completed"), (3, "closed", "completed"),
                          (4, "closed", "completed")])
        self.assertTrue(corpus["issues"][0]["epic"])
        closed_call = next(call for call in self.calls() if "closed" in call)
        self.assertIn("sort:updated-desc", closed_call)

    def test_51_an_oversized_corpus_is_refused(self):
        huge = [raw(n, body="界" * 5000, title="界" * 500) for n in range(1, 501)]
        closed = [raw(n, "CLOSED", body="界" * 5000, title="界" * 500) for n in range(501, 1001)]
        result = self.work_issues({"open": huge, "closed": closed}, "--closed", "--closed-limit", "500")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exceeds its output bound", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_52_success_writes_only_bounded_json_to_stdout(self):
        body = "<!-- form hint -->\n### Problem\n" + "word " * 1000 + "\n### Notes\n_No response_"
        result = self.work_issues({"open": [raw(1, body=body, title="t" * 400)], "closed": []})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "", "the agent tool merges stderr into the JSON it parses")
        entry = json.loads(result.stdout)["issues"][0]
        self.assertEqual(len(entry["title"]), 200)
        self.assertLessEqual(len(entry["body"]), 1000)
        for scaffolding in ("form hint", "###", "_No response_"):
            self.assertNotIn(scaffolding, entry["body"])


if __name__ == "__main__":
    unittest.main()
