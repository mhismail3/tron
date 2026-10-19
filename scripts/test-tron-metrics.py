#!/usr/bin/env python3
"""CLI tests for `scripts/tron metrics` (tools/metrics/README.md).

Each case copies the real `scripts/tron` and `tools/metrics/metrics.py` into a
disposable Git repository with an isolated HOME and Git configuration, commits
fixture files with fixed dates, and runs the command as a worker would:

1. Classification, line counting and the 500-line threshold follow the
   documented rules, and every unmeasured plan metric is reported unavailable
   without a number.
2. The same commit yields byte-identical JSON regardless of working-tree,
   index, untracked-file or time-zone state, and an older commit is measured
   without checking it out.
3. The hotspot window is anchored to the measured commit (not the clock),
   excludes merges and its open lower bound, and ranks ties by path.
4. `--compare` pairs renames, subtracts deletions, reports reclassification and
   follows files over 500 lines through renames; its rows sum to the total.
5. An unknown revision fails loudly and writes nothing.

The last comparison is kept in `test-results/metrics-cli/` for review.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "metrics-cli"
TOOL_FILES = ("scripts/tron", "tools/metrics/metrics.py")
DAY = 86400
T0 = 1_700_000_000  # 2023-11-14: far from the wall clock, so clock anchoring fails loudly.
UNAVAILABLE = {
    "M1.lockCoverage", "M1.lockDeterminism", "M1.lockSensitivity",
    "M2.layerViolations", "M2.directoryCycles", "M2.fileSizeExceptions",
    "M2.registrationFootprint", "M2.navigationProbe", "M4.sliceVerifyTime",
    "ownership.ledger",
}


def lines(count: int, prefix: str = "line") -> str:
    return "".join(f"{prefix} {index}\n" for index in range(count))


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(home),
            "TMPDIR": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.git("init", "-q", "-b", "main")
        for relative in TOOL_FILES:
            target = self.path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)

    def git(self, *args: str, date: int | None = None) -> str:
        env = dict(self.env)
        if date is not None:
            env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"@{date} +0000"
        return subprocess.run(
            ["git", *args], cwd=self.path, env=env, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ).stdout.strip()

    def write(self, relative: str, content: str | bytes) -> None:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content.encode() if isinstance(content, str) else content)

    def commit(self, message: str, date: int, *paths: str) -> str:
        self.git("add", "-A", *paths)
        self.git("commit", "-q", "--allow-empty", "-m", message, date=date)
        return self.git("rev-parse", "HEAD")

    def metrics(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.path / "scripts/tron"), "metrics", *args], cwd=self.path,
            env={**self.env, **(env or {})}, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, check=False,
        )

    def output(self, sha: str) -> Path:
        return self.path / "test-results" / "metrics" / f"{sha}.json"


class RepoCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-metrics-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def measure(self, *args: str) -> subprocess.CompletedProcess:
        result = self.repo.metrics(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result


class ClassificationTests(RepoCase):
    EXPECTED = {
        "packages/gateway/src/core.ts": ("production", 3),
        "packages/gateway/src/core.integration.test.ts": ("tests", 2),
        "packages/gateway/test-support/helper.ts": ("tests", 1),
        "packages/gateway/vitest.config.ts": ("tests", 1),
        "packages/gateway/test-fixtures/trace.golden.json": ("fixtures", 900),
        "packages/gateway/src/sessions/fixtures/frozen.json": ("fixtures", 1),
        "packages/protocol-fixtures/contract.json": ("fixtures", 1),
        "packages/gateway/package-lock.json": ("lockfile", 2),
        "packages/gateway/artifacts/x-package-lock.json": ("lockfile", 1),
        "packages/gateway/package.json": ("data", 1),
        "packages/gateway/third_party/pi/tron.patch": ("thirdParty", 4),
        "packages/mac-app/scripts/cua-driver-LICENSE.txt": ("thirdParty", 1),
        "packages/ios-app/Sources/App/HostedChatFixture.swift": ("tests", 1),
        "packages/ios-app/Sources/UI/ChatHostedProbe.swift": ("tests", 1),
        "packages/ios-app/Sources/State/InAppNoticeCenter.swift": ("production", 1),
        "packages/ios-app/Sources/UI/Unterminated.swift": ("production", 2),
        "packages/ios-app/Sources/Assets/icon.png": ("binary", 0),
        "packages/ios-app/UITests/SmokeUITests.swift": ("tests", 1),
        "packages/ios-app/project.yml": ("data", 1),
        "packages/mac-app/scripts/bundle.sh": ("tooling", 1),
        "packages/mac-app/scripts/tron-gateway-launcher.c": ("production", 1),
        "packages/mac-app/scripts/test-launcher.sh": ("tests", 1),
        "packages/mac-app/native/build.py": ("tooling", 1),
        "scripts/helper": ("tooling", 2),
        "scripts/notes": ("data", 1),
        "scripts/test-helper.py": ("tests", 1),
        "docs/guide.md": ("docs", 600),
        "docs/empty.md": ("docs", 0),
        "packages/gateway/src/exactly-500.ts": ("production", 500),
        "packages/gateway/src/over-500.ts": ("production", 501),
        "packages/gateway/src/big.test.ts": ("tests", 700),
    }

    def setUp(self) -> None:
        super().setUp()
        contents = {
            "packages/gateway/src/core.ts": lines(3),
            "packages/gateway/src/core.integration.test.ts": lines(2),
            "packages/gateway/test-fixtures/trace.golden.json": lines(900),
            "packages/gateway/package-lock.json": "{\n}\n",
            "packages/gateway/third_party/pi/tron.patch": lines(4),
            "packages/ios-app/Sources/UI/Unterminated.swift": "let a = 1\nlet b = 2",
            "packages/ios-app/Sources/Assets/icon.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\n\n",
            "scripts/helper": "#!/usr/bin/env bash\necho hi\n",
            "scripts/notes": "plain text without a shebang\n",
            "docs/guide.md": lines(600),
            "docs/empty.md": "",
            "packages/gateway/src/exactly-500.ts": lines(500),
            "packages/gateway/src/over-500.ts": lines(501),
            "packages/gateway/src/big.test.ts": lines(700),
        }
        for relative in self.EXPECTED:
            self.repo.write(relative, contents.get(relative, "x\n"))
        self.sha = self.repo.commit("fixture", T0)
        self.result = self.measure()
        self.data = json.loads(self.repo.output(self.sha).read_text())

    def test_categories_lines_and_threshold_follow_documented_rules(self) -> None:
        files = {f["path"]: f for f in self.data["files"]}
        for relative, (category, count) in self.EXPECTED.items():
            with self.subTest(path=relative):
                self.assertEqual((files[relative]["category"], files[relative]["lines"]), (category, count))
        self.assertEqual(files["packages/ios-app/Sources/Assets/icon.png"]["bytes"], 18)
        self.assertEqual({f["category"] for f in self.data["files"] if f["path"] in TOOL_FILES}, {"tooling"})

        size = self.data["metrics"]["M3.size"]
        hand = [f for f in self.data["files"] if f["category"] in ("production", "tests", "tooling", "docs")]
        self.assertEqual(size["handWrittenLines"], sum(f["lines"] for f in hand))
        self.assertEqual(size["handWrittenFiles"], len(hand))
        self.assertEqual(size["byCategory"]["fixtures"]["lines"], 902)
        self.assertEqual(sum(row["tests"] for row in size["handWrittenByPackage"].values()),
                         size["byCategory"]["tests"]["lines"])

        large = self.data["metrics"]["M2.fileSize"]
        self.assertEqual([f["path"] for f in large["files"]],
                         ["packages/gateway/src/big.test.ts", "docs/guide.md",
                          "packages/gateway/src/over-500.ts"])
        self.assertEqual(large["byCategory"], {"production": 1, "tests": 1, "tooling": 0, "docs": 1})
        self.assertIn("Hand-written files > 500 lines: 3", self.result.stdout)

    def test_unmeasured_plan_metrics_are_unavailable_without_numbers(self) -> None:
        metrics = self.data["metrics"]
        self.assertEqual({k for k, v in metrics.items() if v["status"] == "unavailable"}, UNAVAILABLE)
        for key in UNAVAILABLE:
            with self.subTest(metric=key):
                self.assertEqual(set(metrics[key]), {"status", "reason", "owner"})
                self.assertTrue(metrics[key]["reason"] and metrics[key]["owner"])
        self.assertEqual({k for k, v in metrics.items() if v["status"] == "observed"},
                         {"M2.fileSize", "M2.hotspotShare", "M3.size"})
        for key in UNAVAILABLE:
            self.assertIn(key, self.result.stdout)


class DeterminismTests(RepoCase):
    def test_commit_measurement_ignores_worktree_index_clock_and_checkout(self) -> None:
        self.repo.write("packages/gateway/src/a.ts", lines(10))
        first = self.repo.commit("first", T0)
        self.measure()
        expected = self.repo.output(first).read_bytes()

        self.repo.write("packages/gateway/src/a.ts", lines(99))
        self.repo.write("packages/gateway/src/untracked.ts", lines(5))
        self.repo.git("add", "packages/gateway/src/a.ts")
        self.repo.write("docs/unstaged.md", lines(3))
        again = self.repo.metrics(env={"TZ": "Pacific/Kiritimati"})
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.repo.output(first).read_bytes(), expected)

        self.repo.git("reset", "-q", "--hard")
        self.repo.git("clean", "-fdq")
        self.repo.write("packages/gateway/src/a.ts", lines(20))
        second = self.repo.commit("second", T0 + DAY)
        self.measure(first)
        self.assertEqual(self.repo.output(first).read_bytes(), expected)
        self.measure(second)
        self.assertEqual(json.loads(self.repo.output(second).read_text())["metrics"]["M3.size"]
                         ["byCategory"]["production"]["lines"], 20)


class HotspotTests(RepoCase):
    def touch(self, message: str, date: int, *names: str) -> str:
        for name in names:
            path = self.repo.path / "hot" / name
            previous = path.read_text() if path.exists() else ""
            self.repo.write(f"hot/{name}", previous + f"{message}\n")
        return self.repo.commit(message, date)

    def test_window_is_anchored_to_the_measured_commit(self) -> None:
        self.repo.commit("tooling", T0 - 400 * DAY)
        self.touch("old", T0 - 31 * DAY, "f11")
        self.touch("boundary", T0 - 30 * DAY, "f09", "f11")
        self.touch("c1", T0 - 20 * DAY, "f00", "f01")
        self.touch("c2", T0 - 19 * DAY, "f00")
        c3 = self.touch("c3", T0 - 18 * DAY, "f00", *[f"f0{i}" for i in range(2, 10)])
        self.touch("c4", T0 - 12 * DAY, "f10")
        self.repo.git("checkout", "-q", "-b", "side")
        self.touch("s1", T0 - 10 * DAY, "f10")
        self.repo.git("checkout", "-q", "main")
        # The merge's own first-parent diff touches f10 again; merges must not count.
        self.repo.git("merge", "-q", "--no-ff", "-m", "merge side", "side", date=T0 - 2 * DAY)
        head = self.touch("c5", T0, "f11")

        self.measure(head)
        hot = json.loads(self.repo.output(head).read_text())["metrics"]["M2.hotspotShare"]
        self.assertEqual((hot["windowStart"], hot["windowEnd"]), ("2023-10-15T22:13:20Z", "2023-11-14T22:13:20Z"))
        self.assertEqual((hot["commits"], hot["touchingTop"], hot["share"]), (6, 5, 0.8333))
        self.assertEqual(
            [(t["path"], t["commits"]) for t in hot["top"]],
            [("hot/f00", 3), ("hot/f10", 2)] + [(f"hot/f0{i}", 1) for i in range(1, 9)],
        )

        self.measure(c3)
        earlier = json.loads(self.repo.output(c3).read_text())["metrics"]["M2.hotspotShare"]
        self.assertEqual((earlier["commits"], earlier["windowEnd"]), (5, "2023-10-27T22:13:20Z"))
        self.assertEqual(earlier["top"][0], {"path": "hot/f00", "commits": 3})
        self.assertIn({"path": "hot/f11", "commits": 2}, earlier["top"])


class CompareTests(RepoCase):
    def test_compare_pairs_renames_subtracts_deletions_and_never_gates(self) -> None:
        big = lines(600, "big")
        mover = lines(30, "mover")
        self.repo.write("packages/gateway/src/big.ts", big)
        self.repo.write("packages/gateway/src/gone.ts", lines(40, "gone"))
        self.repo.write("packages/gateway/src/dead.ts", lines(700, "dead"))
        self.repo.write("packages/gateway/src/shrink.ts", lines(520, "shrink"))
        self.repo.write("packages/gateway/src/mover.ts", mover)
        self.repo.write("docs/keep.md", lines(10, "keep"))
        base = self.repo.commit("base", T0)

        (self.repo.path / "packages/gateway/src/core").mkdir()
        self.repo.git("mv", "packages/gateway/src/big.ts", "packages/gateway/src/core/big.ts")
        self.repo.write("packages/gateway/src/core/big.ts", big + "one more\n")
        self.repo.git("mv", "packages/gateway/src/mover.ts", "scripts/mover.ts")
        self.repo.git("rm", "-q", "packages/gateway/src/gone.ts", "packages/gateway/src/dead.ts")
        self.repo.write("packages/gateway/src/shrink.ts", lines(480, "shrink"))
        self.repo.write("docs/keep.md", lines(15, "keep"))
        self.repo.write("packages/gateway/src/grow.ts", lines(510, "grow"))
        head = self.repo.commit("head", T0 + DAY)

        result = self.measure("--compare", base)
        out = result.stdout
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / "compare.md").write_text(out)
        self.assertTrue(self.repo.output(base).exists() and self.repo.output(head).exists())

        rows = dict(re.findall(r"^\| (added|deleted|renamed|modified) \| (\d+ \| [-+0-9,]+) \|$", out, re.M))
        self.assertEqual(rows, {"added": "1 | +510", "deleted": "2 | -740",
                                "renamed": "2 | +1", "modified": "2 | -35"})
        total = re.search(r"^\| Hand-written lines \| [\d,]+ \| [\d,]+ \| ([-+0-9,]+) \|$", out, re.M)
        self.assertEqual(total.group(1), "-264")
        self.assertIn("| reclassified | 1 |", out)
        self.assertIn("- reclassified: packages/gateway/src/mover.ts → scripts/mover.ts (production → tooling)", out)
        self.assertIn("- >500 renamed: packages/gateway/src/big.ts → packages/gateway/src/core/big.ts (600 → 601)", out)
        self.assertIn("- >500 left: packages/gateway/src/dead.ts (700; deleted)", out)
        self.assertIn("- >500 left: packages/gateway/src/shrink.ts (520; now 480)", out)
        self.assertIn("- >500 entered: packages/gateway/src/grow.ts (510)", out)
        self.assertNotIn("entered: packages/gateway/src/core/big.ts", out)
        self.assertIn("Metrics Δ: LOC prod/test/tool/docs -299/0/+30/+5; files>500 -1;", out)


class FailureTests(RepoCase):
    def test_unknown_revision_fails_loudly_and_writes_nothing(self) -> None:
        self.repo.commit("only", T0)
        for args in (("no-such-rev",), ("--compare", "no-such-rev")):
            with self.subTest(args=args):
                result = self.repo.metrics(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown revision: no-such-rev", result.stderr)
                self.assertFalse((self.repo.path / "test-results").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
