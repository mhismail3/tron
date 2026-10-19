#!/usr/bin/env python3
"""CLI tests for `scripts/tron verify` (tools/verify/README.md).

Each case copies the real `scripts/tron`, `tools/verify` and the checkers it runs
(`tools/ownership`, `tools/budgets`, `tools/metrics`, `tools/layers`, `tools/work`,
the documentation policy and privacy guard) into a disposable Git repository whose
modules own real Python tests, and runs verify as a worker would:

1. A change inside one module selects only that module's tests, and a failing one
   fails the run after its log tail is printed; the static checks ran first.
2. A change in a kernel-layer (L0-L2) module or an unowned path widens to every lock.
3. A change whose modules own no test fails as a zero-test run.
4. An uncommitted tree is refused, the report records the selection and steps, and
   two runs of the same commit have the same result digest.

The last run's output is kept in `test-results/verify-cli/`.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "verify-cli"
COPIED = ["scripts/tron", "scripts/check-documentation-policy.py", "scripts/personal-info-guard.sh",
          "scripts/ios-test-build-identity.py", ".github/work.json",
          *[str(p.relative_to(ROOT)) for d in ("tools/verify", "tools/ownership", "tools/budgets", "tools/metrics", "tools/layers", "tools/work")
            for p in (ROOT / d).glob("*.py")]]
PASSING = "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(True)\nunittest.main()\n"
FAILING = "import unittest\nclass T(unittest.TestCase):\n    def test_broken(self):\n        self.assertEqual(1, 2)\nunittest.main()\n"


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base), "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_NOSYSTEM": "1", "WORK_GH": "/nonexistent-gh",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git("init", "-q", "-b", "main")
        for relative in COPIED:
            (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.path / relative)
        self.write(".gitignore", "test-results/\n")
        self.write("README.md", "# Fixture\n")
        self.write("AGENTS.md", "# Charter\n")
        # The copied tools keep the over-budget exceptions they carry in the real repository.
        oversized = [relative for relative in COPIED if relative.endswith(".py")
                     and len((ROOT / relative).read_text().splitlines()) > 500]
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/tron", "scripts/check-documentation-policy.py", "scripts/personal-info-guard.sh",
            "scripts/ios-test-build-identity.py", ".github/**", "tools/**", "README.md", "AGENTS.md", ".gitignore", "tooling.module.json"],
            "exceptions": [{"path": path, "budget": "lines", "reason": "copied tool", "exit": "real repository"} for path in oversized]}))
        for name, layer in (("alpha", "L3"), ("beta", "L3"), ("core", "L1"), ("docs", "L5")):
            self.write(f"mods/{name}/{name}.module.json", json.dumps({"layer": layer, "owns": ["**"]}))
            self.write(f"mods/{name}/{name}.py", f"VALUE = '{name}'\n")
        self.write("mods/alpha/test-alpha.py", PASSING)
        self.write("mods/beta/test-beta.py", PASSING)
        self.write("mods/core/test-core.lock.py", PASSING)
        self.commit("base")
        self.git("branch", "base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        (self.path / relative).write_text(text)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def verify(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.path / "scripts/tron"), "verify", "--base", "base", *args], cwd=self.path,
                                env=self.env, capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron verify {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result

    def report(self) -> dict:
        sha = self.git("rev-parse", "HEAD")
        return json.loads((self.path / "test-results" / "verify" / f"{sha}.json").read_text())


class VerifyCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-verify-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()


class SelectionTests(VerifyCase):
    def test_one_module_change_runs_only_its_tests_and_a_failure_fails_loudly(self) -> None:
        r = self.repo
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("alpha change")
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        report = r.report()
        self.assertEqual(report["selection"]["modules"], ["repo/alpha"])
        self.assertEqual(report["selection"]["tests"], ["mods/alpha/test-alpha.py"])
        self.assertEqual(report["verdict"], "passed")
        self.assertEqual([step["name"] for step in report["steps"]][:5],
                         ["ownership", "budgets", "documentation policy", "privacy guard", "git diff --check"])
        self.assertIn("[1/", passed.stdout)
        moved = next(step for step in report["steps"] if step["name"] == "moved-lines (advisory)")
        self.assertEqual(moved["status"], "ok")
        self.assertEqual(len(list((r.path / "test-results/measure").glob("*.json"))), 1)
        # A measurement failure remains visible, without becoming a gate.
        # --changed still compares against base, so alpha's test stays selected.
        r.write("tools/metrics/moved.py", "raise SystemExit(2)\n")
        r.commit("unavailable measurement")
        advisory = r.verify("--changed")
        self.assertEqual(advisory.returncode, 0, advisory.stdout + advisory.stderr)
        self.assertEqual(next(step for step in r.report()["steps"] if step["name"] == "moved-lines (advisory)")["status"], "advisory")
        r.write("mods/alpha/test-alpha.py", FAILING)
        r.commit("break alpha")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("tests: python FAILED", failed.stdout)
        self.assertIn("AssertionError: 1 != 2", failed.stdout)
        self.assertNotIn("mods/beta/test-beta.py", json.dumps(r.report()["selection"]["tests"]))

    def test_kernel_layer_or_unowned_change_widens_to_every_lock(self) -> None:
        r = self.repo
        r.write("mods/core/core.py", "VALUE = 'kernel change'\n")
        r.commit("kernel change")
        result = r.verify("--changed", "--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("widened to every lock", result.stdout)
        self.assertIn("repo/core (L1)", result.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("stray/notes.py", "VALUE = 1\n")
        r.commit("unowned change")
        stray = r.verify("--changed", "--plan")
        self.assertIn("widened to every lock", stray.stdout)
        self.assertIn("unowned stray/notes.py", stray.stdout)
        # The run itself refuses at the ownership step, before any test.
        self.assertIn("ownership FAILED", r.verify("--changed").stdout)

    def test_a_selection_without_tests_fails_as_zero_test(self) -> None:
        r = self.repo
        r.write("mods/docs/docs.py", "VALUE = 'prose'\n")
        r.commit("docs change")
        result = r.verify("--changed")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("zero tests ran: an empty selection is not evidence", result.stdout)
        self.assertEqual(r.report()["verdict"], "failed")


class ContractTests(VerifyCase):
    def test_a_runner_group_that_runs_zero_tests_fails(self) -> None:
        r = self.repo
        r.write("mods/beta/test-beta.py", "import unittest\nunittest.main()\n")  # a unittest file with no test
        r.commit("empty beta tests")
        result = r.verify("--module", "repo/beta")
        self.assertEqual(result.returncode, 1, result.stdout)
        report = r.report()
        self.assertEqual(report["verdict"], "failed")
        self.assertEqual(report["passingTests"], 0)
        runner = next(step for step in report["steps"] if step["name"] == "tests: python")
        self.assertEqual(runner["status"], "failed")
        # unittest >= 3.14 exits 5 for no tests; older versions exit 0 and report a zero count.
        self.assertIn(runner["exit"], (0, 5))
        self.assertEqual(runner["tests"], 0 if runner["exit"] == 0 else None)

    def test_uncommitted_tree_is_refused_and_results_are_reproducible(self) -> None:
        r = self.repo
        r.write("mods/beta/beta.py", "VALUE = 'beta change'\n")
        refused = r.verify("--changed")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("commit first", refused.stderr)
        r.commit("beta change")
        digests = []
        for _ in range(2):
            self.assertEqual(r.verify("--module", "repo/beta").returncode, 0)
            digests.append(r.report()["resultDigest"])
        self.assertEqual(digests[0], digests[1])
        self.assertEqual(r.report()["passingTests"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
