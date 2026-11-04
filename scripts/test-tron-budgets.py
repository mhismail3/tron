#!/usr/bin/env python3
"""CLI tests for `scripts/tron budgets` (tools/budgets/README.md).

Each case copies the real `scripts/tron`, `tools/budgets` and `tools/metrics`
into a disposable Git repository and commits a change:

1. Docs fail only above twice their budget (package README 200, other README
   150, other docs 300); the root README is not this checker's. Code files of
   any size are not this checker's either.
2. An unknown revision is an error (exit 2), never clean.

The last run's output is kept in `test-results/budgets-cli/`.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "budgets-cli"
TOOLS = ("scripts/tron", "tools/metrics/metrics.py", "tools/budgets/budgets.py")
APP = "packages/gateway/src/app"


def lines(count: int, prefix: str = "line") -> str:
    return "".join(f"{prefix} {i}\n" for i in range(count))


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
            (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.path / relative)
        self.write("README.md", lines(400))  # root README: the documentation policy's budget
        self.write(f"{APP}/big.ts", lines(600))
        self.write(f"{APP}/huge.ts", lines(900))  # code of any size is not this checker's
        self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        (self.path / relative).write_text(text)

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

    def problems(self, code: int) -> list[str]:
        result = self.repo.budgets()
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return [line for line in result.stdout.splitlines() if not line.startswith("budgets:")]


class DocTests(BudgetCase):
    def test_docs_fail_only_above_twice_their_budget(self) -> None:
        r = self.repo
        r.write("packages/gateway/README.md", lines(400))
        r.write("docs/tool/README.md", lines(300))
        r.write("docs/fine.md", lines(600))
        r.write("README.md", lines(900))
        r.commit("docs within twice their budget")
        self.assertEqual(self.problems(0), [])
        self.assertIn("3 docs over budget (reported)", r.budgets().stdout)
        r.write("packages/gateway/README.md", lines(401))
        r.write("docs/tool/README.md", lines(301))
        r.write("docs/fine.md", lines(601))
        r.commit("docs over twice their budget")
        self.assertEqual(self.problems(1), [
            "doc over 2x budget: docs/fine.md has 601 lines; budget is 300, limit 600 (split it by owner)",
            "doc over 2x budget: docs/tool/README.md has 301 lines; budget is 150, limit 300 (split it by owner)",
            "doc over 2x budget: packages/gateway/README.md has 401 lines; budget is 200, limit 400 (split it by "
            "owner)",
        ])


class ErrorTests(BudgetCase):
    def test_unknown_revision_is_an_error(self) -> None:
        unknown = self.repo.budgets("nope")
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("budgets: unknown revision: nope", unknown.stderr)
        self.assertNotIn("no doc over", unknown.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
