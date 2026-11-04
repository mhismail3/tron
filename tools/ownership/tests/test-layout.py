#!/usr/bin/env python3
"""CLI tests for the repository layout rules in `scripts/tron ownership` (tools/ownership/README.md).

Each case copies the real `scripts/tron` and `tools/ownership/*.py` into a disposable Git
repository whose `root.module.json` declares a `layout`, then runs the command as a
worker would. One case per rule, each failing with the message that names its fix:

1. Root entries, `scripts/` top-level files and frozen paths follow the declared lists.
2. Tooling under `scripts/`, `tools/` and package `scripts/` states its purpose in its
   first lines; directive comments (shellcheck, coding, eslint) do not count.
3. Tests sit beside the code they prove: never in the root, `docs/`, `config/`,
   `.agents/` or `.github/`; Swift tests only in test targets.
4. The seeded lists only shrink: an entry with nothing left to allow is stale, an entry
   missing at the merge base with origin/main is refused, and a frozen path cannot be
   unfrozen and removed in one change. Without origin/main the check exits 2.
5. `--ledger` lists every tracked path once with its module, layer and purpose.
6. `layout` is accepted only in root.module.json and its keys are checked.

The last run's output is kept in `test-results/layout-cli/` for review.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "test-results" / "layout-cli"
PURPOSE = "#!/usr/bin/env bash\n# Fixture tool that a test runs to prove one layout rule.\n"
LAYOUT = {
    "root": [".gitignore", "docs", "packages", "root.module.json", "scripts", "tools"],
    "scriptsTop": ["scripts/tron", "scripts/tron-frozen"],
    "frozen": ["scripts/tron", "scripts/tron-frozen"],
}


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.git("init", "-q", "-b", "main")
        (self.path / "tools/ownership").mkdir(parents=True)
        (self.path / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/tron", self.path / "scripts/tron")
        for tool in (ROOT / "tools/ownership").glob("*.py"):
            shutil.copy2(tool, self.path / "tools/ownership" / tool.name)
        self.write("scripts/tron-frozen", PURPOSE, mode=0o755)
        self.write(".gitignore", "test-results/\n")
        self.write("docs/guide.md", "# Guide\n")
        self.write("packages/gateway/src/home/home.ts", "export const home = 1;\n")
        self.layout = json.loads(json.dumps(LAYOUT))
        self.save_root()
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/**", "tools/**", "docs/**", "packages/**", ".gitignore", "tooling.module.json"]}))
        self.layout["root"].append("tooling.module.json")
        self.save_root()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def save_root(self, layout: object = None, extra: dict | None = None) -> None:
        data = {"layer": "L5", "owns": ["root.module.json"], "layout": self.layout if layout is None else layout}
        self.write("root.module.json", json.dumps({**data, **(extra or {})}))

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, content: str = "x\n", mode: int | None = None) -> None:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        if mode is not None:
            target.chmod(mode)

    def run(self, *args: str) -> subprocess.CompletedProcess:
        self.git("add", "-A")
        result = subprocess.run([str(self.path / "scripts/tron"), "ownership", *args], cwd=self.path,
                                env=self.env, capture_output=True, text=True, check=False)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron ownership {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result


class LayoutCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-layout-")
        self.repo = Repo(Path(self.temp.name).resolve())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def clean(self) -> None:
        result = self.repo.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def refused(self, *fragments: str) -> str:
        result = self.repo.run()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)
        return result.stdout


class PlacementRuleTests(LayoutCase):
    def test_declared_layout_passes(self) -> None:
        self.clean()

    def test_new_root_entry_is_refused_with_its_fix(self) -> None:
        self.repo.write("notes.txt")
        self.refused("layout: root entry 'notes.txt' is not in the layout; put it under scripts/, docs/, config/ or a package")

    def test_new_flat_script_is_refused(self) -> None:
        self.repo.write("scripts/helper.sh", PURPOSE, mode=0o755)
        self.refused("layout: scripts/helper.sh: scripts/ top level holds only the commands listed in root.module.json")

    def test_new_flat_tooling_test_is_refused(self) -> None:
        self.repo.write("scripts/test-helper.py", "print('ok')\n")
        self.refused("layout: scripts/test-helper.py: tests live beside the tool they prove")

    def test_missing_frozen_path_is_refused(self) -> None:
        (self.repo.path / "scripts/tron-frozen").unlink()
        self.repo.layout["scriptsTop"].remove("scripts/tron-frozen")
        self.repo.save_root()
        self.refused("layout: scripts/tron-frozen is missing: code older than this checkout runs this path; restore it")


class PurposeRuleTests(LayoutCase):
    def test_tooling_without_a_purpose_line_is_refused(self) -> None:
        self.repo.write("tools/ownership/helper.py", "import sys\nprint(sys.argv)\n")
        self.repo.write("packages/gateway/scripts/check.mjs", "#!/usr/bin/env node\nimport fs from 'node:fs';\n")
        self.repo.write("packages/gateway/src/scripts/source.ts", "export const value = 1;\n")  # source, not tooling
        out = self.refused("layout: tools/ownership/helper.py: add a one-line purpose comment",
                           "layout: packages/gateway/scripts/check.mjs: add a one-line purpose comment")
        self.assertNotIn("tools/ownership/ownership.py", out)
        self.assertNotIn("source.ts", out)

    def test_directive_comments_are_not_a_purpose(self) -> None:
        self.repo.write("tools/ownership/helper.sh", "#!/bin/bash\n# shellcheck disable=SC2034\n# -*- coding: utf-8 -*-\nset -e\n")
        self.refused("layout: tools/ownership/helper.sh: add a one-line purpose comment")

    def test_a_purpose_line_after_directives_passes(self) -> None:
        self.repo.write("tools/ownership/helper.sh", "#!/bin/bash\n# shellcheck disable=SC2034\n# Prints the fixture state for one test.\n")
        self.repo.write("tools/ownership/helper.mjs", "/**\n * Prints the fixture state for one test.\n */\n")
        self.clean()


class TestPlacementRuleTests(LayoutCase):
    def test_tests_outside_the_code_they_prove_are_refused(self) -> None:
        self.repo.write("docs/test-guide.py", "print('ok')\n")
        self.refused("layout: docs/test-guide.py: tests live beside the code they prove, never in docs/")

    def test_swift_tests_belong_in_a_test_target(self) -> None:
        self.repo.write("packages/ios/Sources/ChatTests.swift", "import XCTest\n")
        self.repo.write("packages/ios/UITests/ChatUITests.swift", "import XCTest\n")
        out = self.refused("layout: packages/ios/Sources/ChatTests.swift: Swift tests belong in a test target")
        self.assertNotIn("UITests/ChatUITests.swift:", out)


class RatchetTests(LayoutCase):
    def test_stale_entries_must_be_removed(self) -> None:
        r = self.repo
        r.layout["root"].append("gone")
        r.layout["scriptsTop"].append("scripts/gone.sh")
        r.save_root()
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "seed")
        r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.refused("layout: root.module.json layout.root lists 'gone', which is not tracked; remove it",
                     "layout: root.module.json layout.scriptsTop lists 'scripts/gone.sh', which is not tracked; remove it")

    def test_lists_only_shrink_against_the_merge_base(self) -> None:
        r = self.repo
        r.write("extra/file.txt")
        r.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/**", "tools/**", "docs/**", "packages/**", "extra/**", ".gitignore", "tooling.module.json"]}))
        r.layout["root"].append("extra")
        r.save_root()
        self.refused("layout: root.module.json layout.root gained 'extra' since origin/main; these lists only shrink")
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "grow")
        r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.clean()  # once main has the entry, a later branch sees no growth

    def test_a_frozen_path_cannot_be_unfrozen_and_removed_in_one_change(self) -> None:
        r = self.repo
        (r.path / "scripts/tron-frozen").unlink()
        r.layout["frozen"].remove("scripts/tron-frozen")
        r.layout["scriptsTop"].remove("scripts/tron-frozen")
        r.save_root()
        self.refused("layout: scripts/tron-frozen was frozen at origin/main and this change unfreezes and removes it")
        r.write("scripts/tron-frozen", PURPOSE, mode=0o755)  # unfreezing alone, keeping the file, passes
        r.layout["scriptsTop"].append("scripts/tron-frozen")
        r.save_root()
        self.clean()

    def test_without_origin_main_the_shrink_check_cannot_run(self) -> None:
        r = self.repo
        r.git("update-ref", "-d", "refs/remotes/origin/main")
        result = r.run()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ownership: cannot find the merge base with origin/main", result.stderr)

    def test_invalid_layout_at_the_merge_base_is_an_error_not_a_skip(self) -> None:
        r = self.repo
        r.write("root.module.json", "{not json")
        r.git("add", "-A")
        r.git("commit", "-q", "-m", "broken base")
        r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        r.save_root()
        result = r.run()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("root.module.json at merge base", result.stderr)
        self.assertIn("is not valid JSON", result.stderr)

    def test_a_shrunk_list_passes(self) -> None:
        r = self.repo
        (r.path / "docs/guide.md").unlink()
        r.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/**", "tools/**", "packages/**", ".gitignore", "tooling.module.json"]}))
        r.layout["root"].remove("docs")
        r.save_root()
        self.clean()


class SchemaAndLedgerTests(LayoutCase):
    def test_layout_belongs_only_to_root_manifest_and_keys_are_checked(self) -> None:
        r = self.repo
        r.write("docs/docs.module.json", json.dumps({"layer": "L5", "owns": ["guide.md", "docs.module.json"],
                                                     "layout": {"root": []}}))
        r.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/**", "tools/**", "packages/**", ".gitignore", "tooling.module.json"]}))
        r.layout["bogus"] = []
        r.save_root()
        self.refused("docs/docs.module.json: layout is declared only in root.module.json",
                     "root.module.json: layout has unknown key 'bogus'")

    def test_ledger_lists_every_tracked_path_with_owner_and_purpose(self) -> None:
        r = self.repo
        r.save_root(extra={"purpose": "Root files and the repository layout"})
        result = r.run("--ledger")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = [line.split("\t") for line in result.stdout.splitlines()]
        self.assertEqual(rows[0], ["path", "module", "layer", "purpose"])
        by_path = {row[0]: row[1:] for row in rows[1:]}
        self.assertEqual(sorted(by_path), sorted(r.git("ls-files").splitlines()))
        self.assertEqual(by_path["scripts/tron-frozen"],
                         ["repo/tooling", "L5", "Fixture tool that a test runs to prove one layout rule."])
        self.assertEqual(by_path["root.module.json"], ["repo/root", "L5", "Root files and the repository layout"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
