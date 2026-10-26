#!/usr/bin/env python3
"""Real-boundary regression for scripts/tron-fsevents-guard (#2038).

Every case runs the real script with /usr/bin/python3 (the LaunchAgent's
interpreter) as a process against a fixture HOME and temp dir. It reads the real
fseventsd and the real `lsof`; thresholds pin whether the daemon counts as hot,
so no case depends on the machine's current fseventsd state.

Failure modes:
  1. A stale Tron mkdtemp root is not removed, or anything else is removed: a
     fresh root, a stale root with one recent descendant, a non-Tron directory,
     a keyed e2e cache, a plain file, or a symlink named like a fixture.
  2. A root that a live process holds (an open file, or its working directory)
     is removed.
  3. Removal follows a symlink out of the fixture and deletes its target.
  4. The per-pass cap is ignored, so a backlog is removed in one burst.
  5. Removal runs while fseventsd is hot, and `--dry-run` removes anything.
  6. The alert fires before the sustain count, or again within the alert
     interval.
  7. The LaunchAgent plist does not embed this exact source with a valid
     argument order, or its program does not run.
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "tron-fsevents-guard"
PYTHON = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
COLD = ["--cpu-alert-percent", "100000", "--footprint-alert-mb", "1e12"]
HOT = ["--cpu-alert-percent", "0", "--footprint-alert-mb", "0"]
OLD = time.time() - 3 * 86400


def make_tree(root, files=3, age=OLD):
    (root / "nested" / "deeper").mkdir(parents=True)
    for index in range(files):
        (root / "nested" / "deeper" / ("f%d" % index)).write_text("x")
    for path in sorted(root.rglob("*"), key=lambda p: -len(p.parts)) + [root]:
        os.utime(path, (age, age), follow_symlinks=False)


@unittest.skipUnless(sys.platform == "darwin", "macOS fseventsd guard")
class FseventsGuard(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="fsevents-guard-test-")).resolve()
        self.home = self.base / "home"
        self.temp = self.base / "T"
        self.home.mkdir()
        self.temp.mkdir()
        self.held = []

    def tearDown(self):
        for process in self.held:
            process.kill()
            process.wait()
        shutil.rmtree(self.base, ignore_errors=True)

    def guard(self, *args, extra_env=None):
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        env.update(extra_env or {})
        result = subprocess.run([PYTHON, str(SCRIPT), "--temp-dir", str(self.temp), *args],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def check(self, *args):
        output = self.guard("check", "--sample-seconds", "0.2", *args)
        log = self.home / "Library" / "Logs" / "tron-fsevents-guard.jsonl"
        return output, json.loads(log.read_text().splitlines()[-1])

    def test_removes_only_provably_stale_unheld_tron_roots_without_following_links(self):
        stale = self.temp / "tron-sync-race-Ab12Cd"
        make_tree(stale)
        python_stale = self.temp / "tron-work-start-1jah02ho"
        make_tree(python_stale)
        fresh = self.temp / "tron-sync-slot-Zz9Yy8"
        make_tree(fresh, age=time.time())
        recent_leaf = self.temp / "tron-terminal-Qw3Er4"
        make_tree(recent_leaf)
        os.utime(recent_leaf / "nested" / "deeper" / "f0", None)
        foreign = self.temp / "addon-0063fc"
        make_tree(foreign)
        keyed = self.temp / "tron-ios-gateway-e2e-derived-501-worktree-2b7cce43b307"
        make_tree(keyed)
        keyed_short = self.temp / "tron-ios-gateway-e2e-Ab12Cd"
        make_tree(keyed_short)
        plain = self.temp / "tron-lock-Ab12Cd"
        plain.write_text("x")
        os.utime(plain, (OLD, OLD))
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        link_root = self.temp / "tron-link-Ab12Cd"
        link_root.symlink_to(outside, target_is_directory=True)
        escaping = self.temp / "tron-escape-Ab12Cd"
        make_tree(escaping)
        (escaping / "out").symlink_to(outside, target_is_directory=True)
        os.utime(escaping / "out", (OLD, OLD), follow_symlinks=False)
        os.utime(escaping, (OLD, OLD))
        held_file = self.temp / "tron-held-file-Ab12Cd"
        make_tree(held_file)
        held_cwd = self.temp / "tron-held-cwd-Ab12Cd"
        make_tree(held_cwd)
        self.held.append(subprocess.Popen([PYTHON, "-c", "import sys,time; f=open(sys.argv[1]); time.sleep(120)",
                                           str(held_file / "nested" / "deeper" / "f1")]))
        self.held.append(subprocess.Popen(["/bin/sleep", "120"], cwd=str(held_cwd / "nested")))
        time.sleep(0.5)

        _, record = self.check(*COLD)

        removed = {stale.name, python_stale.name, escaping.name}
        kept = [fresh, recent_leaf, foreign, keyed, keyed_short, plain, link_root, held_file, held_cwd]
        self.assertEqual(set(record["cleanup"]["deleted"]), removed, record)
        for path in (stale, python_stale, escaping):
            self.assertFalse(os.path.lexists(path), path)
        for path in kept:
            self.assertTrue(os.path.lexists(path), path)
        self.assertEqual((outside / "keep.txt").read_text(), "keep")
        self.assertEqual(record["cleanup"]["keptInUse"], 2, record)
        self.assertEqual(record["cleanup"]["keptRecent"], 2, record)
        self.assertFalse(record["hot"])

    def test_caps_removal_per_pass(self):
        roots = [self.temp / ("tron-backlog-%s" % suffix) for suffix in ("Aa11Aa", "Bb22Bb", "Cc33Cc")]
        for root in roots:
            make_tree(root)
        _, first = self.check(*COLD, "--max-delete-roots", "1")
        self.assertEqual(len(first["cleanup"]["deleted"]), 1, first)
        self.assertEqual(first["cleanup"]["deferred"], 2, first)
        self.assertEqual(sum(root.exists() for root in roots), 2)
        _, second = self.check(*COLD, "--max-delete-entries", "8")
        self.assertEqual(len(second["cleanup"]["deleted"]), 1, second)
        self.assertEqual(sum(root.exists() for root in roots), 1)

    def test_hot_daemon_defers_removal_and_alerts_once_after_sustain(self):
        stale = self.temp / "tron-sync-race-Ab12Cd"
        make_tree(stale)
        outputs = []
        records = []
        for _ in range(3):
            output, record = self.check(*HOT, "--sustain-passes", "2", "--alert-interval-hours", "6")
            outputs.append(output)
            records.append(record)
        self.assertTrue(all(record["hot"] for record in records))
        self.assertEqual([record["consecutiveHot"] for record in records], [1, 2, 3])
        self.assertEqual(["alert" in record for record in records], [False, True, False])
        self.assertIn("ALERT fseventsd pid", outputs[1])
        self.assertIn("sudo killall fseventsd", records[1]["alert"])
        self.assertIn("skipped", records[0]["cleanup"])
        self.assertTrue(stale.exists())
        _, dry = self.check(*HOT, "--dry-run")
        self.assertEqual(dry["cleanup"]["wouldDelete"], [stale.name])
        self.assertTrue(stale.exists())

    def test_launch_agent_embeds_this_source_and_its_program_runs(self):
        plist = plistlib.loads(self.guard("install", "--print-plist", "--interval-minutes", "15").encode())
        program = plist["ProgramArguments"]
        self.assertEqual(plist["Label"], "com.tron.fsevents-guard")
        self.assertEqual(plist["StartInterval"], 900)
        self.assertEqual(program[:2], ["/usr/bin/python3", "-c"])
        self.assertEqual(program[2], SCRIPT.read_text())
        self.assertEqual(program[3:], ["--temp-dir", str(self.temp), "check", "--notify"])
        self.assertFalse((self.home / "Library" / "LaunchAgents").exists())
        stale = self.temp / "tron-agent-run-Ab12Cd"
        make_tree(stale)
        # Run the agent's exact program once; COLD keeps the pass from alerting
        # or deferring regardless of the machine's fseventsd.
        result = subprocess.run([PYTHON, *program[1:], "--sample-seconds", "0.2", *COLD],
                                env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        status = self.guard("status")
        self.assertIn("tron-agent-run-Ab12Cd", status)


if __name__ == "__main__":
    unittest.main()
