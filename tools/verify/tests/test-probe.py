#!/usr/bin/env python3
"""CLI tests for `scripts/tron probe` (tools/verify/README.md, "Removal probes").

Each case copies the real `scripts/tron`, `tools/verify`, `tools/ownership` and the layers index
helper verify imports into a disposable Git repository and probes one unit as a worker would:

1. precise: deleting a tool whose test runs it turns that test red, and the failure names it.
2. cascade: deleting a data file the tool reads quietly turns several tests red without naming it.
3. silent: deleting a file no test reaches turns nothing red.
4. A move that leaves its callers behind turns the callers' tests red and the card check names
   every file still using the old path; the caller's test is chosen because it names the caller,
   which names the tool.
5. A guardian already red at HEAD stops the probe with exit 1 before any change.

Every run leaves no scratch worktree behind. The last run's output is kept in `test-results/probe-cli/`.
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
ARTIFACTS = ROOT / "test-results" / "probe-cli"
COPIED = ["scripts/tron", "tools/layers/swift_index.py",
          *[str(p.relative_to(ROOT)) for d in ("tools/verify", "tools/ownership") for p in (ROOT / d).glob("*.py")]]
TOOL = '#!/usr/bin/env bash\n# Prints the greeting kept beside it.\ncat "$(dirname "$0")/greeting.txt" 2>/dev/null\n'
TOOL_TEST = ('#!/usr/bin/env bash\n# Proves tool.sh prints the greeting.\n'
             'out=$(bash tools/tool/tool.sh) || { echo "tools/tool/tool.sh failed"; exit 1; }\n'
             '[[ $out == hello ]] || { echo "unexpected output: $out"; exit 1; }\n')
CALLER = '#!/usr/bin/env bash\n# Greets through the tool.\nbash tools/tool/tool.sh\n'
CALLER_TEST = ('#!/usr/bin/env bash\n# Proves the caller greets.\n'
               'out=$(bash tools/caller/caller.sh 2>&1)\n[[ $out == hello ]] || { echo "caller said: $out"; exit 1; }\n')


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(base / "home"), "TMPDIR": str(base),
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        (base / "home").mkdir()
        self.git("init", "-q", "-b", "main")
        for relative in COPIED:
            (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.path / relative)
        self.write(".gitignore", "test-results/\n")
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": ["scripts/**", "tools/verify/**", "tools/ownership/**",
                                                                             "tools/layers/**", ".gitignore", "tooling.module.json"]}))
        self.write("tools/tool/tool.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.write("tools/tool/tool.sh", TOOL, mode=0o755)
        self.write("tools/tool/greeting.txt", "hello\n")
        self.write("tools/tool/unused.sh", "#!/usr/bin/env bash\n# Nothing runs this.\n", mode=0o755)
        self.write("tools/tool/tests/test-tool.sh", TOOL_TEST)
        for index in range(6):
            self.write(f"tools/tool/tests/test-greeting-{index}.sh", TOOL_TEST.replace("prints the greeting", f"greets ({index})"))
        self.write("tools/caller/caller.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        self.write("tools/caller/caller.sh", CALLER, mode=0o755)
        self.write("tools/caller/tests/test-caller.sh", CALLER_TEST)
        self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str, mode: int | None = None) -> None:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        if mode is not None:
            target.chmod(mode)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def probe(self, *args: str) -> tuple[subprocess.CompletedProcess, dict]:
        result = subprocess.run([str(self.path / "scripts/tron"), "probe", *args, "--jobs", "2"], cwd=self.path,
                                env=self.env, capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron probe {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        reports = sorted((self.path / "test-results/probe").glob("*/*/report.json"), key=lambda p: p.stat().st_mtime)
        return result, json.loads(reports[-1].read_text()) if reports else {}


class ProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-probe-test-")
        self.repo = Repo(Path(self.temp.name).resolve())

    def tearDown(self) -> None:
        worktrees = self.repo.git("worktree", "list", "--porcelain").count("worktree ")
        self.assertEqual(worktrees, 1, "the probe left a scratch worktree registered")
        self.temp.cleanup()

    def test_deleting_a_guarded_tool_is_precise(self) -> None:
        result, report = self.repo.probe("tools/caller/caller.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["verdict"], "precise", result.stdout)
        self.assertEqual(report["failing"], ["tools/caller/tests/test-caller.sh"])
        self.assertIn("verdict: PRECISE", result.stdout)
        self.assertIn("caller.sh", result.stdout)

    def test_a_quietly_missing_input_is_a_cascade(self) -> None:
        result, report = self.repo.probe("tools/tool/greeting.txt")
        self.assertEqual(report["verdict"], "cascade", result.stdout)
        self.assertEqual(len(report["failing"]), 7)  # the tool's own tests; no other module names the file
        self.assertIn("does not name the unit", result.stdout)

    def test_an_unreached_file_is_silent(self) -> None:
        result, report = self.repo.probe("tools/tool/unused.sh")
        self.assertEqual(report["verdict"], "silent", result.stdout)
        self.assertEqual(report["failing"], [])

    def test_a_move_that_leaves_its_callers_behind_names_them(self) -> None:
        r = self.repo
        r.write("tools/tool/tool.module.json", json.dumps({
            "layer": "L5", "owns": ["**"], "purpose": "Prints the greeting.",
            "interfaces": [{"name": "tools/tool/tool.sh", "kind": "exec", "consumers": ["repo/caller"]},
                           {"name": "tools/tool/unused.sh", "kind": "exec", "external": "nobody; the silent case"}]}))
        r.write("root.module.json", json.dumps({"layer": "L5", "owns": ["root.module.json"], "layout": {
            "root": [".gitignore", "root.module.json", "scripts", "tools", "tooling.module.json"], "scriptsTop": ["scripts/tron"],
            "frozen": [], "uncarded": ["repo/caller", "repo/root", "repo/tooling"]}}))
        r.commit("card the tool")
        r.git("update-ref", "refs/remotes/origin/main", "HEAD")
        result, report = r.probe("tools/tool/tool.sh", "--move", "tools/tool/bin/tool.sh")
        self.assertEqual(report["verdict"], "precise", result.stdout)
        self.assertIn("tools/caller/tests/test-caller.sh", report["failing"])
        self.assertEqual(report["guardians"]["tools/caller/tests/test-caller.sh"]["why"],
                         "names tools/caller/caller.sh, which names the unit")
        self.assertTrue(any("card interface 'tools/tool/tool.sh' is not a tracked path or directory; still named by "
                            "tools/caller/caller.sh:" in line for line in report["static"]),
                        report["static"])

    def test_a_red_baseline_stops_before_any_change(self) -> None:
        self.repo.write("tools/caller/tests/test-caller.sh", "#!/usr/bin/env bash\n# Always red.\nexit 1\n")
        self.repo.commit("red")
        result, report = self.repo.probe("tools/caller/caller.sh")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(report["baselineRed"], ["tools/caller/tests/test-caller.sh"])
        self.assertIn("already fail at HEAD", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
