#!/usr/bin/env python3
"""Failure modes: a changed path skips its verify check; a deleted or renamed
path loses its owner; an unrelated path selects a check; a missing, zero or
unresolvable base skips coverage; an unknown check name is silently unselected;
the GitHub output format drifts from the `name=true|false` lines the workflow reads.

Each case runs the real CLI in a temporary Git repository. The check globs come
from the repository's `.github/work.json`, so CI and verify share one definition.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name("ci_verify_scope.py")
NAMES = ("pi-subagents", "dev-lifecycle-state", "profiler", "gateway-payload-deploy")


def only(name):
    return {check: check == name for check in NAMES}


class VerifyScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.git("config", "commit.gpgsign", "false")
        self.write("README.md")
        self.commit("fixture")
        self.base = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def write(self, path, text="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)

    def change(self, path):
        """Commit one change to `path` and return the commit before it."""
        base = self.git("rev-parse", "HEAD")
        self.write(path)
        self.commit(f"change {path}")
        return base

    def run_cli(self, base, *names, output=None):
        args = [sys.executable, str(SCRIPT), "--base", base, "--head", "HEAD"]
        if output is not None:
            args += ["--github-output", str(output)]
        result = subprocess.run([*args, *names], cwd=self.repo, text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_each_check_selects_its_own_verify_paths(self):
        for path, owner in [
            ("packages/gateway/scripts/check-pi-subagents.mjs", "pi-subagents"),
            ("packages/gateway/artifacts/pi-subagents-0.76.1-tron.3.tgz", "pi-subagents"),
            ("scripts/tron-dev", "dev-lifecycle-state"),
            ("scripts/tron-dev-state.mjs", "dev-lifecycle-state"),
            ("scripts/tron-profile-gateway-driver.mjs", "profiler"),
            ("scripts/tron_profile_report.py", "profiler"),
            ("scripts/gateway-payload-deploy.mjs", "gateway-payload-deploy"),
            ("scripts/gateway-payload-deploy.test.mjs", "gateway-payload-deploy"),
        ]:
            with self.subTest(path=path):
                base = self.change(path)
                self.assertEqual(self.run_cli(base, *NAMES)["checks"], only(owner))

    def test_unrelated_and_empty_diffs_select_no_check(self):
        base = self.change("packages/ios-app/Sources/Chat.swift")
        self.assertEqual(self.run_cli(base, *NAMES)["checks"], {name: False for name in NAMES})
        self.assertEqual(self.run_cli(self.git("rev-parse", "HEAD"), *NAMES)["checks"],
                         {name: False for name in NAMES})

    def test_deleted_path_keeps_its_owner_selected(self):
        self.write("scripts/tron-dev-state.mjs")
        self.commit("add owned file")
        base = self.git("rev-parse", "HEAD")
        (self.repo / "scripts/tron-dev-state.mjs").unlink()
        self.commit("delete owned file")
        self.assertEqual(self.run_cli(base, *NAMES)["checks"], only("dev-lifecycle-state"))

    def test_renamed_path_keeps_its_old_owner_selected(self):
        self.write("scripts/gateway-payload-deploy.mjs")
        self.commit("add owned file")
        base = self.git("rev-parse", "HEAD")
        (self.repo / "docs").mkdir()
        self.git("mv", "scripts/gateway-payload-deploy.mjs", "docs/moved-deploy.md")
        self.commit("rename owned file out")
        self.assertEqual(self.run_cli(base, *NAMES)["checks"], only("gateway-payload-deploy"))

    def test_missing_or_unresolvable_base_selects_every_check(self):
        for base, reason in [("", "missing-base"), ("0" * 40, "missing-base"),
                             ("missing-ref", "diff-unavailable")]:
            with self.subTest(base=base):
                payload = self.run_cli(base, *NAMES)
                self.assertEqual(payload["checks"], {name: True for name in NAMES})
                self.assertEqual(payload["reason"], reason)

    def test_unknown_check_name_fails_open_and_reports_the_error(self):
        payload = self.run_cli(self.base, "pi-subagents", "not-a-check")
        self.assertEqual(payload["reason"], "error")
        self.assertEqual(payload["checks"], {"pi-subagents": True, "not-a-check": True})

    def test_github_output_appends_name_and_lowercase_boolean_lines(self):
        output = self.repo / "github-output"
        output.write_text("existing=kept\n")
        base = self.change("scripts/tron-profile-gateway-driver.mjs")
        self.run_cli(base, *NAMES, output=output)
        self.assertEqual(output.read_text().splitlines(), [
            "existing=kept",
            "pi-subagents=false",
            "dev-lifecycle-state=false",
            "profiler=true",
            "gateway-payload-deploy=false",
        ])


if __name__ == "__main__":
    unittest.main()
