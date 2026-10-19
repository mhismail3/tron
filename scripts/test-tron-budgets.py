#!/usr/bin/env python3
"""CLI tests for `scripts/tron budgets` (tools/budgets/README.md).

Each case copies the real `scripts/tron`, `tools/budgets`, `tools/metrics` and
`tools/ownership` into a disposable Git repository and commits fixture files:

1. The change that introduces the checker may seed exceptions; later changes may not.
2. Known-bad: a grown excepted file, a new oversized file, and an exception added
   for it all fail; 500 lines passes and 501 fails (the metrics threshold).
3. Shrinking is allowed, a file back within budget makes its exception stale,
   and removing the exception passes. A renamed excepted file keeps its
   exception and its size bound.
4. Doc budgets: package README 200, other README 150, other docs 300; the root
   README is left to the documentation policy.
5. An unknown base or an ownership violation is an error (exit 2), never clean.

The last run's output is kept in `test-results/budgets-cli/`.
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
ARTIFACTS = ROOT / "test-results" / "budgets-cli"
TOOLS = ("scripts/tron", "tools/metrics/metrics.py", "tools/ownership/ownership.py")
APP = "packages/gateway/src/app"
EXIT = {"reason": "fixture", "exit": "split it"}


def lines(count: int) -> str:
    return "".join(f"line {i}\n" for i in range(count))


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base),
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git("init", "-q", "-b", "main")
        for relative in TOOLS:
            self.copy(relative)
        self.manifest("tooling.module.json", {"layer": "L5", "owns": ["scripts/**", "tools/**", "tooling.module.json",
                                                                      "README.md"]})
        self.write("README.md", lines(400))  # root README: documentation policy's budget, not this checker's
        self.app([])
        self.write(f"{APP}/big.ts", lines(600))
        self.write(f"{APP}/small.ts", lines(10))
        self.commit("base without the checker")

    def copy(self, relative: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, self.path / relative)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        (self.path / relative).write_text(text)

    def manifest(self, relative: str, data: dict) -> None:
        self.write(relative, json.dumps(data))

    def app(self, exceptions: list) -> None:
        self.manifest(f"{APP}/app.module.json", {"layer": "L3", "owns": ["**"],
                                                 "exceptions": [{"path": p, "budget": b, **EXIT} for p, b in exceptions]})

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def budgets(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.path / "scripts/tron"), "budgets", *args], cwd=self.path, env=self.env,
                                capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron budgets {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result


class BudgetCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-budgets-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def problems(self, code: int, *args: str) -> list[str]:
        result = self.repo.budgets("--base", "main", *args)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return [line for line in result.stdout.splitlines() if not line.startswith("budgets:")]

    def seeded(self) -> None:
        """Introduce the checker with big.ts excepted, then make that the base."""
        r = self.repo
        r.git("checkout", "-q", "-B", "slice")
        r.copy("tools/budgets/budgets.py")
        r.app([("big.ts", "lines")])
        r.commit("introduce budgets")
        self.assertIn("(seeded; main has no budget checker); every file within budget or excepted",
                      r.budgets("--base", "main").stdout)
        r.git("checkout", "-q", "main")
        r.git("merge", "-q", "--ff-only", "slice")
        r.git("checkout", "-q", "slice")  # later commits are a slice over that base


class SeedTests(BudgetCase):
    def test_only_the_introducing_change_seeds_and_unexcepted_files_fail(self) -> None:
        r = self.repo
        r.git("checkout", "-q", "-b", "unexcepted")
        r.copy("tools/budgets/budgets.py")
        r.commit("checker without exceptions")
        self.assertEqual(self.problems(1), [
            f"over budget: {APP}/big.ts has 600 lines; lines budget is 500 (split it; exceptions are never added)"])
        self.seeded()
        self.assertEqual(self.problems(0), [])


class KnownBadTests(BudgetCase):
    def test_growth_new_oversized_files_and_new_exceptions_fail(self) -> None:
        self.seeded()
        r = self.repo
        r.write(f"{APP}/big.ts", lines(601))
        r.write(f"{APP}/edge.ts", lines(500))
        r.write(f"{APP}/new.ts", lines(501))
        r.commit("known-bad")
        self.assertEqual(self.problems(1), [
            f"over budget: {APP}/new.ts has 501 lines; lines budget is 500 (split it; exceptions are never added)",
            f"grew: {APP}/big.ts (lines) 600 -> 601 lines (excepted files may only shrink)",
        ])
        r.app([("big.ts", "lines"), ("new.ts", "lines")])
        r.commit("relax")
        self.assertEqual(self.problems(1), [
            f"grew: {APP}/big.ts (lines) 600 -> 601 lines (excepted files may only shrink)",
            f"new exception: {APP}/new.ts (lines) in gateway/app is not excepted at main; split the file instead",
        ])


class ShrinkTests(BudgetCase):
    def test_shrink_stale_removal_and_rename(self) -> None:
        self.seeded()
        r = self.repo
        r.write(f"{APP}/big.ts", lines(550))
        r.commit("shrink")
        self.assertEqual(self.problems(0), [])
        r.git("mv", f"{APP}/big.ts", f"{APP}/huge.ts")
        r.app([("huge.ts", "lines")])
        r.commit("rename")
        self.assertEqual(self.problems(0), [])
        r.write(f"{APP}/huge.ts", lines(500))
        r.commit("within budget")
        self.assertEqual(self.problems(1), [
            f"stale exception: {APP}/huge.ts (lines) in gateway/app is within budget (500 lines); remove it"])
        r.app([])
        r.commit("remove the exception")
        self.assertEqual(self.problems(0), [])


class DocTests(BudgetCase):
    def test_doc_budgets_by_kind(self) -> None:
        self.seeded()
        r = self.repo
        r.manifest("docs.module.json", {"layer": "L5", "owns": ["docs/**", "packages/gateway/README.md",
                                                                "docs.module.json"]})
        r.write("packages/gateway/README.md", lines(201))
        r.write("docs/tool/README.md", lines(151))
        r.write("docs/contract.md", lines(301))
        r.write("docs/fine.md", lines(300))
        r.commit("docs")
        self.assertEqual(self.problems(1), [
            "over budget: docs/contract.md has 301 lines; doc budget is 300 (split it; exceptions are never added)",
            "over budget: docs/tool/README.md has 151 lines; doc budget is 150 (split it; exceptions are never added)",
            "over budget: packages/gateway/README.md has 201 lines; doc budget is 200 (split it; exceptions are never "
            "added)",
        ])


class ErrorTests(BudgetCase):
    def test_unknown_base_and_ownership_violations_are_errors(self) -> None:
        self.seeded()
        r = self.repo
        unknown = r.budgets("--base", "nope")
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("base nope cannot be measured", unknown.stderr)
        r.write("stray.ts", "x\n")
        r.commit("unowned")
        stray = r.budgets("--base", "main")
        self.assertEqual(stray.returncode, 2)
        self.assertIn("ownership at HEAD has 1 violation(s)", stray.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
