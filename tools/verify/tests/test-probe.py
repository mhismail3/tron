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
5. A guardian already red at HEAD is left out and reported; with no green guardian left the probe
   stops with exit 1 before any change.
6. SIGTERM stops every running test's process group and removes every scratch worktree, also
   when the stopped group is already reaped (macOS then reports EPERM).
7. A guardian that seals a tree read-only leaves no scratch behind, and guardians running side by
   side each get their own checkout: one writing into its tree never dirties another's.
8. A short unit name ("tron") that also occurs in scratch paths does not count as naming the unit,
   so a vague failure is still a cascade; Python's "No module named '<stem>'" does name a .py unit.
9. Deleting a guardian's own runner (scripts/tron-node) is a failure that names it, not a crash;
   a relay test is listed as not run, never run as a shell script.
10. A checkout that cannot be prepared (unreadable dependencies, or a move under a tracked file)
    is a `probe:` error, exit 2.
11. A guardian that reinstalls Gateway dependencies changes only the probe's own copy, never the
   checkout's (bundle-gateway.sh runs `npm ci`).

Every run leaves no scratch worktree behind. The last run's output is kept in `test-results/probe-cli/`.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
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
        result = subprocess.run([str(self.path / "scripts/tron"), "probe", "--jobs", "2", *args], cwd=self.path,
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
        listed = self.repo.git("worktree", "list", "--porcelain")
        self.assertEqual(listed.count("worktree "), 1, f"the probe left a scratch worktree registered:\n{listed}\n"
                                                       f"{getattr(self, 'last_output', '')}")
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
        self.assertIn("tools/tool/tool.sh failed", result.stdout)  # the vague red still shows what it said

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

    def test_a_guardian_red_at_head_is_left_out_and_reported(self) -> None:
        r = self.repo
        r.write("tools/tool/tests/test-greeting-0.sh", "#!/usr/bin/env bash\n# Always red.\nexit 1\n")
        r.commit("one red guardian")
        result, report = r.probe("tools/tool/tool.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["baselineRed"], ["tools/tool/tests/test-greeting-0.sh"])
        self.assertEqual(report["verdict"], "precise")
        self.assertNotIn("tools/tool/tests/test-greeting-0.sh", report["failing"])
        self.assertIn("already fail at HEAD and are left out", result.stderr)

    def test_with_every_guardian_red_at_head_nothing_is_changed(self) -> None:
        self.repo.write("tools/caller/tests/test-caller.sh", "#!/usr/bin/env bash\n# Always red.\nexit 1\n")
        self.repo.commit("red")
        result, report = self.repo.probe("tools/caller/caller.sh")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(report["baselineRed"], ["tools/caller/tests/test-caller.sh"])
        self.assertNotIn("verdict", report)

    def test_sigterm_stops_running_tests_and_removes_the_worktree(self) -> None:
        r = self.repo
        marker = f"61.{os.getpid() % 100000:05d}"  # a sleep only this run starts
        r.write("tools/caller/tests/test-caller.sh", f"#!/usr/bin/env bash\n# Slow guardian that cleans up when stopped.\n"
                f"trap 'touch \"$HOME/stopped\"; exit 1' TERM\nsleep {marker} &\nwait\n")
        r.commit("slow")
        process = subprocess.Popen([str(r.path / "scripts/tron"), "probe", "tools/caller/caller.sh"], cwd=r.path, env=r.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.time() + 30
        while time.time() < deadline and subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode:
            time.sleep(0.1)
        self.assertEqual(subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode, 0,
                         "the slow guardian never started")
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=30)
        self.last_output = output
        self.assertNotEqual(process.returncode, 0, output)
        self.assertEqual(subprocess.run(["pgrep", "-f", f"sleep {marker}"], capture_output=True).returncode, 1,
                         "a guardian's process outlived the probe")
        self.assertTrue((Path(r.env["HOME"]) / "stopped").exists(), "the guardian got no SIGTERM to clean up on")

    def test_a_timed_out_guardian_gets_sigterm_to_clean_up(self) -> None:
        r = self.repo
        r.write("tools/caller/tests/test-caller.sh", "#!/usr/bin/env bash\n# Hangs until stopped, then cleans up.\n"
                "trap 'touch \"$HOME/stopped\"; exit 1' TERM\nsleep 300 &\nwait\n")
        r.commit("hangs")
        result, report = r.probe("tools/caller/caller.sh", "--timeout", "2")
        self.assertEqual(report["baselineRed"], ["tools/caller/tests/test-caller.sh"], result.stdout + result.stderr)
        self.assertTrue((Path(r.env["HOME"]) / "stopped").exists(), result.stdout + result.stderr)

    def test_a_guardian_that_seals_a_tree_read_only_leaves_no_scratch_behind(self) -> None:
        r = self.repo
        r.write("tools/caller/tests/test-caller.sh", CALLER_TEST.replace(
            "out=$(", "mkdir -p \"$TMPDIR/sealed/a\" sealed/b && touch \"$TMPDIR/sealed/a/f\" sealed/b/f && "
                      "chmod -R a-w \"$TMPDIR/sealed\" sealed\nout=$("))
        r.commit("a guardian that seals its output")
        result, report = r.probe("tools/caller/caller.sh")
        self.assertEqual(report["verdict"], "precise", result.stdout + result.stderr)
        left = sorted(path.name for path in Path(self.temp.name).iterdir() if path.name.startswith(("probe-test-", "tron-probe-")))
        self.assertEqual(left, [], result.stderr)

    def test_guardians_side_by_side_never_share_a_checkout(self) -> None:
        r = self.repo
        r.write("tools/tool/tests/test-greeting-0.sh", "#!/usr/bin/env bash\n# Writes into its checkout.\n"
                "touch stray-output.txt\nsleep 2\nbash tools/tool/tool.sh >/dev/null\n")
        r.write("tools/tool/tests/test-greeting-1.sh", "#!/usr/bin/env bash\n# Needs a clean checkout.\nsleep 1\n"
                "[[ -z $(git status --porcelain) ]] || { echo \"dirty checkout: $(git status --porcelain)\"; exit 1; }\n"
                "[[ $(bash tools/tool/tool.sh) == hello ]] || { echo 'tools/tool/tool.sh failed'; exit 1; }\n")
        r.commit("a writer and a reader of the checkout")
        result, report = r.probe("tools/tool/tool.sh", "--jobs", "8")
        self.assertEqual(report.get("baselineRed", []), [], result.stdout + result.stderr)
        self.assertIn("tools/tool/tests/test-greeting-1.sh", report["failing"])

    def test_python_naming_a_missing_module_names_the_unit(self) -> None:
        r = self.repo
        r.write("tools/tool/glue.py", "# Shared helper the tool imports.\nGREETING = 'hello'\n")
        r.write("tools/tool/tests/test-glue.sh", "#!/usr/bin/env bash\n# Imports the helper by module name.\n"
                "python3 -c \"import sys; sys.path.insert(0, 'tools/tool'); import glue; print(glue.GREETING)\"\n")
        r.commit("a helper imported by its module name")
        result, report = r.probe("tools/tool/glue.py")
        self.assertIn("No module named 'glue'", (r.path / report["guardians"]["tools/tool/tests/test-glue.sh"]["after"]["log"]).read_text())
        self.assertEqual(report["verdict"], "precise", result.stdout)

    def test_a_short_name_in_a_scratch_path_does_not_name_the_unit(self) -> None:
        r = self.repo
        r.write("tools/tool/tron", "hello\n")
        r.write("tools/tool/tool.sh", TOOL.replace("greeting.txt", "tron"), mode=0o755)
        vague = ("#!/usr/bin/env bash\n# Vague about what broke.\n"
                 '[[ $(bash tools/tool/tool.sh) == hello ]] || { echo "unexpected output in $PWD"; exit 1; }\n')
        for test in ["test-tool.sh", *(f"test-greeting-{index}.sh" for index in range(6))]:
            r.write(f"tools/tool/tests/{test}", vague)
        r.commit("a unit with a short name")
        result, report = r.probe("tools/tool/tron")
        self.assertIn("tron-probe-", (r.path / report["guardians"]["tools/tool/tests/test-greeting-0.sh"]["after"]["log"]).read_text())
        self.assertEqual(report["verdict"], "cascade", result.stdout)

    def test_a_deleted_runner_names_itself_and_relay_tests_are_not_run(self) -> None:
        r = self.repo
        r.write("scripts/tron-node", "#!/bin/bash\n# Fixture runner: every node test passes.\nexit 0\n", mode=0o755)
        r.write("tools/tool/tests/runner.test.mjs", "// Runs through scripts/tron-node.\n")
        r.write("packages/push-relay/relay.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        r.write("packages/push-relay/tests/worker.test.ts", "// Needs the relay's own runner: scripts/tron-node.\n")
        r.commit("a node guardian and a relay test")
        result, report = r.probe("scripts/tron-node")
        self.assertEqual(report["verdict"], "precise", result.stdout + result.stderr)
        self.assertIn("tools/tool/tests/runner.test.mjs", report["failing"])
        self.assertIn("packages/push-relay/tests/worker.test.ts", report["notRun"])
        self.assertNotIn("packages/push-relay/tests/worker.test.ts", report.get("baselineRed", []))

    def test_a_checkout_that_cannot_be_prepared_is_an_error_not_a_crash(self) -> None:
        r = self.repo
        r.write(".gitignore", "test-results/\nnode_modules/\n")
        r.write("packages/gateway/package.json", "{}\n")
        unreadable = r.path / "packages/gateway/node_modules/.bin/locked"
        r.write("packages/gateway/node_modules/.bin/locked", "x\n")
        r.commit("dependencies a clone cannot read")
        unreadable.chmod(0)
        try:
            result, _ = r.probe("tools/caller/caller.sh")
        finally:
            unreadable.chmod(0o644)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("probe: could not prepare a checkout", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_a_move_under_a_tracked_file_is_an_error_not_a_crash(self) -> None:
        result, _ = self.repo.probe("tools/tool/tool.sh", "--move", "tools/caller/caller.sh/tool.sh")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("probe: could not prepare a checkout", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_a_guardian_that_reinstalls_dependencies_leaves_the_checkouts_copy_alone(self) -> None:
        r = self.repo
        r.write(".gitignore", "test-results/\nnode_modules/\n")
        r.write("packages/gateway/package.json", "{}\n")
        r.write("packages/gateway/node_modules/.bin/tool", "installed\n")
        r.write("tools/caller/tests/test-caller.sh", CALLER_TEST.replace(
            "out=$(", "rm -rf packages/gateway/node_modules/.bin\nout=$("))
        r.commit("a guardian that reinstalls")
        result, report = r.probe("tools/caller/caller.sh")
        self.assertEqual(report["verdict"], "precise", result.stdout + result.stderr)
        self.assertTrue((r.path / "packages/gateway/node_modules/.bin/tool").is_file(),
                        "the probe's guardian removed the checkout's own installed dependencies")


if __name__ == "__main__":
    unittest.main(verbosity=2)
