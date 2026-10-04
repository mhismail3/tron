"""Behavioral CLI coverage for CI selection failure modes (README, CI).

Real Git trees protect deletion/rename and unresolvable input behavior; no YAML
source assertions. The workflow calls this same CLI with its event's base/head.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci_macos_scope.py"
ALL = {"gateway", "ios", "pi-sdk-e2e", "mac"}


class MacOSScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.change("README.md")
        self.base = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def change(self, path):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("changed\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def select(self, base=None, head="HEAD", extra=()):
        result = subprocess.run([sys.executable, str(SCRIPT), "--base", base or self.base,
                                 "--head", head, *extra], cwd=self.repo, text=True,
                                capture_output=True, check=True)
        payload = json.loads(result.stdout)
        return {job for job, run in payload["jobs"].items() if run}, payload

    def test_documentation_and_work_tooling_skip_hosted_macos(self):
        self.change("tools/work/dashboard.py")
        self.assertEqual(self.select()[0], set())
        self.change("packages/ios-app/docs/development.md")
        self.assertEqual(self.select()[0], set())

    def test_shared_gateway_and_native_boundaries_select_consumers(self):
        for path, expected in [
            ("packages/gateway/src/transport.ts", {"gateway", "pi-sdk-e2e", "mac"}),
            ("packages/ios-app/Sources/Chat.swift", {"ios", "pi-sdk-e2e"}),
            ("packages/mac-app/Sources/App.swift", {"mac"}),
            ("packages/protocol-fixtures/events.json", ALL),
            (".github/workflows/ci.yml", ALL),
            ("scripts/ci_macos_scope.py", ALL),
            ("config/ci-toolchain.env", ALL),
            (".node-version", ALL),
        ]:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.change(path)
                self.assertEqual(self.select(base)[0], expected)

    def test_empty_unknown_and_unresolvable_inputs_run_every_job(self):
        self.assertEqual(self.select()[0], ALL)
        self.assertEqual(self.select("missing-ref")[0], ALL)
        self.assertEqual(self.select(head="missing-ref")[0], ALL)
        self.change("new-owner/input.txt")
        self.assertEqual(self.select()[0], ALL)
        self.change("new-owner\nREADME.md")
        self.assertEqual(self.select()[0], ALL)

    def test_deletion_and_rename_keep_old_and_new_owners(self):
        self.change("packages/ios-app/source.swift")
        base = self.git("rev-parse", "HEAD")
        (self.repo / "docs").mkdir()
        self.git("mv", "packages/ios-app/source.swift", "docs/README-ios.md")
        self.git("commit", "-qm", "rename")
        self.assertEqual(self.select(base)[0], {"ios", "pi-sdk-e2e"})

    def test_workflow_selection_step_executes_scoping_dispatch_and_failure_fallback(self):
        # Execute the owning workflow's actual shell, not a source-text assertion.
        workflow = SCRIPT.parent.parent / ".github/workflows/ci.yml"
        shell = subprocess.check_output([
            "ruby", "-ryaml", "-e",
            'puts YAML.load_file(ARGV[0])["jobs"]["policy"]["steps"].find { |s| s["id"] == "macos-scope" }["run"]',
            str(workflow)], text=True)
        self.change("docs/guide.md")
        target = self.repo / "scripts/ci_macos_scope.py"
        target.parent.mkdir()
        target.write_bytes(SCRIPT.read_bytes())
        output = self.repo / "outputs"
        env = {**os.environ, "CI_BASE": self.base, "CI_EVENT": "pull_request", "GITHUB_OUTPUT": str(output)}
        for event, fail_classifier, expected in [("pull_request", False, set()),
                                                   ("workflow_dispatch", False, ALL),
                                                   ("pull_request", True, ALL)]:
            with self.subTest(event=event, fail_classifier=fail_classifier):
                if output.exists():
                    output.unlink()
                if fail_classifier:
                    target.unlink()
                subprocess.run(["bash", "-c", shell], cwd=self.repo,
                               env={**env, "CI_EVENT": event}, check=True, capture_output=True)
                jobs = dict(line.split("=") for line in output.read_text().splitlines())
                self.assertEqual({job for job, value in jobs.items() if value == "true"}, expected)

    def test_two_dot_diff_needs_no_merge_base_and_emits_actions_outputs(self):
        self.git("checkout", "--orphan", "unrelated")
        self.git("rm", "-rf", ".")
        self.change("tools/work/new.py")
        output = self.repo / "outputs"
        jobs, payload = self.select(extra=("--github-output", str(output)))
        self.assertEqual(jobs, set())
        self.assertEqual(payload["reason"], "classified-changed-paths")
        self.assertEqual(dict(line.split("=") for line in output.read_text().splitlines()),
                         {job: "false" for job in ALL})


if __name__ == "__main__":
    unittest.main()
