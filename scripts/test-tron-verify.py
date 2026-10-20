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
5. The iOS lane: an iOS-only change selects the UI locks of the module whose dynamic
   edge reaches it, builds once (a stand-in `scripts/tron-ios-test` compiles a real
   index store with `swiftc` and stamps it with the real identity script), runs the
   real `layers ios` on it, runs the locks by `--only-testing` owner, and reuses the
   build on the next run with an identical digest; a failing or empty XCTest summary
   fails the run.
6. `scripts/tron mutate` over a fake Gateway runner: a mutant whose locks hang is
   stopped at the per-mutant timeout with its whole process group, and an
   interrupted run restores the source and keeps the mutants it finished.

The last run's output is kept in `test-results/verify-cli/`.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
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


# A stand-in for scripts/tron-ios-test with its real output contract: `build` writes a real index store
# and the real build stamp; `run` writes an xcresult-style summary.json and names its run directory.
IOS_TEST_STUB = r"""#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >>"$FIXTURE_IOS_CALLS"
case "$1" in
  build)
    mkdir -p "$TRON_IOS_TEST_DERIVED_DATA/Build/Products"
    find "$root/packages/ios-app" -name '*.swift' | sort | xargs xcrun swiftc -module-name App -parse-as-library \
      -emit-library -o "$TRON_IOS_TEST_DERIVED_DATA/App.dylib" -index-store-path "$TRON_IOS_TEST_DERIVED_DATA/Index.noindex/DataStore"
    python3 "$root/scripts/ios-test-build-identity.py" show --worktree "$root" \
      | python3 "$root/scripts/ios-test-build-identity.py" write --worktree "$root" --derived-data "$TRON_IOS_TEST_DERIVED_DATA"
    echo "Reusable iOS test products ready" ;;
  run)
    dir="$(mktemp -d "$TMPDIR/ios-run.XXXXXX")"
    passed="${FIXTURE_IOS_PASSED:-1}"
    if [[ -n "${FIXTURE_IOS_FAIL:-}" ]]; then
      printf '{"passedTests":0,"failedTests":1,"testFailures":[{"testIdentifierString":"%s","failureText":"a11y differs"}]}' "$FIXTURE_IOS_FAIL" >"$dir/summary.json"
      echo "iOS test run failed with status 65: $dir" >&2; exit 65
    fi
    printf '{"passedTests":%s,"failedTests":0}' "$passed" >"$dir/summary.json"
    echo "iOS test run complete: $dir" ;;
esac
"""


class IosLaneTests(VerifyCase):
    def test_ios_change_builds_once_checks_references_and_runs_only_the_ui_locks(self) -> None:
        r = self.repo
        products = Path(self.temp.name) / "products"
        calls = Path(self.temp.name) / "ios-calls.txt"
        r.env.update(TRON_IOS_TEST_DERIVED_DATA=str(products), FIXTURE_IOS_CALLS=str(calls))
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"].append("scripts/tron-ios-test")
        r.write("tooling.module.json", json.dumps(tooling))
        r.write("scripts/tron-ios-test", IOS_TEST_STUB)
        (r.path / "scripts/tron-ios-test").chmod(0o755)
        ios = "packages/ios-app"
        r.write(f"{ios}/package.module.json", json.dumps({"layer": "L5", "owns": ["*.json"]}))
        r.write(f"{ios}/Sources/UI/Chat/chat.module.json", json.dumps({"layer": "L4", "owns": ["**"]}))
        r.write(f"{ios}/Sources/UI/Chat/ChatView.swift", "struct ChatView {}\n")
        r.write(f"{ios}/UITests/ui-tests.module.json", json.dumps({"layer": "L5", "owns": ["**"], "dynamicEdges": [
            {"to": "ios-app/chat", "kind": "spawn", "via": f"{ios}/package.module.json", "why": "launches the app"}]}))
        r.write(f"{ios}/UITests/Locks/FixtureLockTests.swift", "class FixtureLockTests {}\n")
        r.write(f"{ios}/UITests/FixtureJourneyUITests.swift", "class FixtureJourneyUITests {}\n")
        r.write(f"{ios}/UITests/TronMacTerminalUITests.swift", "class TronMacTerminalUITests {}\n")  # harnessed
        r.commit("ios fixture")
        r.git("branch", "-f", "base")
        r.write(f"{ios}/Sources/UI/Chat/ChatView.swift", "struct ChatView { let title = \"Chat\" }\n")
        r.commit("chat change")

        digests = []
        for _ in range(2):
            result = r.verify("--changed")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = r.report()
            digests.append(report["resultDigest"])
            self.assertEqual(report["selection"]["tests"], [f"{ios}/UITests/Locks/FixtureLockTests.swift"])
            steps = {step["name"]: step for step in report["steps"]}
            self.assertEqual((steps["ios build"]["status"], steps["layers ios"]["status"], steps["tests: ios"]["tests"]),
                             ("ok", "ok", 1))
        self.assertEqual(digests[0], digests[1])
        self.assertIn("already stamped for this commit", steps["ios build"]["detail"])
        self.assertEqual(calls.read_text().splitlines(), ["build", "run --only-testing TronMobileUITests/FixtureLockTests",
                                                          "run --only-testing TronMobileUITests/FixtureLockTests"])

        failed = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                                env={**r.env, "FIXTURE_IOS_FAIL": "TronMobileUITests/FixtureLockTests/testChat()"},
                                capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("tests: ios FAILED", failed.stdout)
        self.assertIn("failed: TronMobileUITests/FixtureLockTests/testChat(): a11y differs", failed.stdout)
        empty = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                               env={**r.env, "FIXTURE_IOS_PASSED": "0"}, capture_output=True, text=True)
        self.assertEqual(empty.returncode, 1, empty.stdout)
        self.assertIn("tests: ios ran zero passing tests", empty.stdout)
        # The module's own journeys run in the lane, except the harnessed one, which its harness runs.
        calls.write_text("")
        module = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(module.returncode, 1, module.stdout)
        self.assertIn("selected tests were not run: ios-lanes", module.stdout)
        self.assertEqual(calls.read_text().splitlines(), [
            "run --only-testing TronMobileUITests/FixtureJourneyUITests --only-testing TronMobileUITests/FixtureLockTests"])


# The Gateway runner `mutate` drives, faked at `scripts/tron-node`: a flipped comparison
# fails the lock, a flipped flag hangs it (with a child the timeout must also stop).
FAKE_RUNNER = """#!/usr/bin/env python3
import json, pathlib, subprocess, sys, time
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--outputFile="))
source = pathlib.Path("src/store/store.ts").read_text()
if "hang = false" in source:
    child = subprocess.Popen(["sleep", "300"])
    pathlib.Path("hung.pid").write_text(f"{child.pid}\\n")
    time.sleep(300)
failed = 0 if "1 === 1" in source else 1
pathlib.Path(out).write_text(json.dumps({"numFailedTests": failed, "numFailedTestSuites": 0, "numPassedTests": 1 - failed}))
"""
SOURCE = "export const kill = 1 === 1;\nexport const hang = true;\n"


class MutateTests(VerifyCase):
    def setUp(self) -> None:
        super().setUp()
        r = self.repo
        r.write("scripts/tron-node", FAKE_RUNNER)
        (r.path / "scripts/tron-node").chmod(0o755)
        r.write("packages/gateway/src/store/store.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/src/store/store.ts", SOURCE)
        r.write("packages/gateway/src/store/store.lock.integration.test.ts", "// faked by scripts/tron-node\n")
        r.write(".gitignore", "test-results/\npackages/gateway/hung.pid\n")
        manifest = json.loads((r.path / "tooling.module.json").read_text())
        manifest["owns"].append("scripts/tron-node")
        r.write("tooling.module.json", json.dumps(manifest))
        r.commit("gateway store")
        # The seed that samples the failing mutant first: candidates are in line order.
        self.seed = next(seed for seed in range(100) if (lambda pool: (random.Random(seed).shuffle(pool), pool)[1])([0, 1]) == [0, 1])

    def mutate(self, *args: str) -> subprocess.Popen:
        return subprocess.Popen([str(self.repo.path / "scripts/tron"), "mutate", "packages/gateway/src/store/store.ts",
                                 "--seed", str(self.seed), *args], cwd=self.repo.path, env=self.repo.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def report(self) -> dict:
        return json.loads((self.repo.path / "test-results/mutate/packages__gateway__src__store__store.ts.json").read_text())

    def assert_hung_child_stopped(self) -> None:
        pid = int((self.repo.path / "packages/gateway/hung.pid").read_text())
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        self.fail(f"the hung lock's child {pid} outlived its mutant")

    def test_a_hanging_mutant_times_out_and_counts_as_detected(self) -> None:
        started = time.time()
        process = self.mutate("--timeout", "3")
        output, _ = process.communicate(timeout=120)
        self.assertEqual(process.returncode, 0, output)
        self.assertLess(time.time() - started, 60, output)
        report = self.report()
        self.assertEqual([(m["line"], m["outcome"]) for m in report["mutants"]], [(1, "killed"), (2, "timeout")])
        self.assertEqual((report["killed"], report["timeouts"], report["rate"], report["complete"]), (2, 1, 1.0, True))
        self.assertIn("TIMEOUT", output)
        self.assertEqual((self.repo.path / "packages/gateway/src/store/store.ts").read_text(), SOURCE)
        self.assert_hung_child_stopped()

    def test_an_interrupted_run_restores_the_source_and_keeps_finished_mutants(self) -> None:
        process = self.mutate("--timeout", "120")
        pid_file = self.repo.path / "packages/gateway/hung.pid"
        deadline = time.time() + 60
        while not pid_file.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(pid_file.exists(), "the hanging mutant never started")
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertEqual((self.repo.path / "packages/gateway/src/store/store.ts").read_text(), SOURCE)
        report = self.report()
        self.assertEqual(([(m["line"], m["outcome"]) for m in report["mutants"]], report["complete"]), ([(1, "killed")], False))
        self.assert_hung_child_stopped()


if __name__ == "__main__":
    unittest.main(verbosity=2)
