#!/usr/bin/env python3
"""Real-boundary regression for scripts/tron-fsevents-guard (#2038).

Every case runs the real script with /usr/bin/python3 (the LaunchAgent's
interpreter) as a process against a fixture HOME and temp dir. It reads the real
fseventsd and the real `lsof`; thresholds pin whether the daemon counts as hot,
so no case depends on the machine's current fseventsd state. Staleness uses
ctime, which no user can set back, so cases age their trees with a real wait
against a seconds-scale threshold.

Failure modes:
  1. A stale Tron mkdtemp root is not removed, or anything else is removed: a
     fresh root, a stale root with one recent descendant, a root copied with
     preserved old mtimes, a non-Tron directory, a keyed e2e cache, a plain
     file, or a symlink named like a fixture.
  2. A root that a live process holds (an open file, or its working directory)
     is removed.
  3. Removal follows a symlink out of the fixture and deletes its target.
  4. The per-pass cap is ignored, so a backlog is removed in one burst; or one
     root too large for any pass blocks every root sorted after it.
  5. Removal runs while fseventsd is hot, and `--dry-run` removes anything.
  6. The alert fires before the sustain count, or again within the alert
     interval.
  7. A shared or other-writable temp dir (/tmp) is scanned at all.
  8. The LaunchAgent plist does not embed this exact source with a valid
     argument order, or its program does not run.

Not exercised here: `install`/`uninstall` against launchd (launchctl acts on the
real user domain whatever HOME is), and lsof failing (fail-closed by code review).
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
AGE_SECONDS = 8
AGED = ["--fixture-age-hours", str(AGE_SECONDS / 3600)]
OLD = time.time() - 3 * 86400


def make_tree(root, files=3):
    (root / "nested" / "deeper").mkdir(parents=True)
    for index in range(files):
        (root / "nested" / "deeper" / ("f%d" % index)).write_text("x")


def age_out():
    time.sleep(AGE_SECONDS + 2)


@unittest.skipUnless(sys.platform == "darwin", "macOS fseventsd guard")
class FseventsGuard(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="fsevents-guard-test-")).resolve()
        self.home = self.base / "home"
        self.temp = self.base / "T"
        self.home.mkdir()
        self.temp.mkdir(mode=0o700)
        self.held = []

    def tearDown(self):
        for process in self.held:
            process.kill()
            process.wait()
        shutil.rmtree(self.base, ignore_errors=True)

    def guard(self, *args, temp=None, status=0):
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        result = subprocess.run([PYTHON, str(SCRIPT), "--temp-dir", str(temp or self.temp), *args],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
        self.assertEqual(result.returncode, status, result.stderr)
        return result.stdout + result.stderr

    def check(self, *args):
        output = self.guard("check", "--sample-seconds", "0.2", *args)
        log = self.home / "Library" / "Logs" / "tron-fsevents-guard.jsonl"
        return output, json.loads(log.read_text().splitlines()[-1])

    def test_removes_only_provably_stale_unheld_tron_roots_without_following_links(self):
        stale = self.temp / "tron-sync-race-Ab12Cd"
        python_stale = self.temp / "tron-work-start-1jah02ho"
        recent_leaf = self.temp / "tron-terminal-Qw3Er4"
        foreign = self.temp / "addon-0063fc"
        keyed = self.temp / "tron-ios-gateway-e2e-derived-501-worktree-2b7cce43b307"
        keyed_short = self.temp / "tron-ios-gateway-e2e-Ab12Cd"
        escaping = self.temp / "tron-escape-Ab12Cd"
        held_file = self.temp / "tron-held-file-Ab12Cd"
        held_cwd = self.temp / "tron-held-cwd-Ab12Cd"
        for root in (stale, python_stale, recent_leaf, foreign, keyed, keyed_short, escaping, held_file, held_cwd):
            make_tree(root)
        plain = self.temp / "tron-lock-Ab12Cd"
        plain.write_text("x")
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        link_root = self.temp / "tron-link-Ab12Cd"
        link_root.symlink_to(outside, target_is_directory=True)
        (escaping / "out").symlink_to(outside, target_is_directory=True)
        age_out()
        fresh = self.temp / "tron-sync-slot-Zz9Yy8"
        make_tree(fresh)
        copied = self.temp / "tron-copied-Cp1Cp2"
        make_tree(copied)
        for path in [*copied.rglob("*"), copied]:
            os.utime(path, (OLD, OLD), follow_symlinks=False)
        os.utime(recent_leaf / "nested" / "deeper" / "f0", None)
        self.held.append(subprocess.Popen([PYTHON, "-c", "import sys,time; f=open(sys.argv[1]); time.sleep(120)",
                                           str(held_file / "nested" / "deeper" / "f1")]))
        self.held.append(subprocess.Popen(["/bin/sleep", "120"], cwd=str(held_cwd / "nested")))
        time.sleep(0.5)

        _, record = self.check(*COLD, *AGED)

        removed = {stale.name, python_stale.name, escaping.name}
        kept = [fresh, copied, recent_leaf, foreign, keyed, keyed_short, plain, link_root, held_file, held_cwd]
        self.assertEqual(set(record["cleanup"]["deleted"]), removed, record)
        for path in (stale, python_stale, escaping):
            self.assertFalse(os.path.lexists(path), path)
        for path in kept:
            self.assertTrue(os.path.lexists(path), path)
        self.assertEqual((outside / "keep.txt").read_text(), "keep")
        self.assertEqual(record["cleanup"]["keptInUse"], 2, record)
        self.assertEqual(record["cleanup"]["keptRecent"], 3, record)
        self.assertFalse(record["hot"])
        self.assertGreater(record["fseventsd"]["footprintMB"], 0, record)
        self.assertGreater(record["fseventsd"]["rssMB"], 0, record)

    def test_removes_only_old_empty_swift_driver_temp_directories(self):
        stale = self.temp / "TemporaryDirectory.Ab12Cd"
        recent = self.temp / "TemporaryDirectory.Ef34Gh"
        nonempty = self.temp / "TemporaryDirectory.Ij56Kl"
        for path in (stale, recent, nonempty):
            path.mkdir()
        (nonempty / "keep").write_text("compiler output")
        outside = self.base / "outside"
        outside.mkdir()
        link = self.temp / "TemporaryDirectory.Mn78Op"
        link.symlink_to(outside, target_is_directory=True)
        for path in (stale, nonempty, outside):
            os.utime(path, (OLD, OLD))
        _, dry = self.check(*COLD, "--dry-run")
        self.assertIn(stale.name, dry["cleanup"].get("wouldDelete", []), dry)
        self.assertTrue(stale.is_dir())
        _, record = self.check(*COLD)
        self.assertEqual(record["cleanup"]["deleted"], [stale.name], record)
        self.assertFalse(stale.exists())
        self.assertTrue(recent.is_dir())
        self.assertEqual((nonempty / "keep").read_text(), "compiler output")
        self.assertTrue(link.is_symlink())
        self.assertTrue(outside.is_dir())

    def test_caps_removal_per_pass_and_skips_roots_too_large_for_any_pass(self):
        oversized = self.temp / "tron-aaa-big-Zz00Zz"
        make_tree(oversized, files=40)
        roots = [self.temp / ("tron-backlog-%s" % suffix) for suffix in ("Aa11Aa", "Bb22Bb", "Cc33Cc")]
        for root in roots:
            make_tree(root)
        age_out()
        _, first = self.check(*COLD, *AGED, "--max-delete-roots", "1", "--max-delete-entries", "20")
        self.assertEqual(first["cleanup"]["keptOversized"], [oversized.name], first)
        self.assertEqual(first["cleanup"]["deleted"], [roots[0].name], first)
        self.assertEqual(first["cleanup"]["deferred"], 2, first)
        _, second = self.check(*COLD, *AGED, "--max-delete-entries", "8")
        self.assertEqual(second["cleanup"]["deleted"], [roots[1].name], second)
        self.assertEqual(second["cleanup"]["deferred"], 1, second)
        self.assertTrue(oversized.exists())
        self.assertTrue(roots[2].exists())

    def test_hot_daemon_defers_removal_and_alerts_once_after_sustain(self):
        stale = self.temp / "tron-sync-race-Ab12Cd"
        make_tree(stale)
        age_out()
        outputs = []
        records = []
        for _ in range(3):
            output, record = self.check(*HOT, *AGED, "--sustain-passes", "2", "--alert-interval-hours", "6")
            outputs.append(output)
            records.append(record)
        self.assertTrue(all(record["hot"] for record in records))
        self.assertEqual([record["consecutiveHot"] for record in records], [1, 2, 3])
        self.assertEqual(["alert" in record for record in records], [False, True, False])
        self.assertIn("ALERT fseventsd pid", outputs[1])
        self.assertIn("sudo killall fseventsd", records[1]["alert"])
        self.assertIn("skipped", records[0]["cleanup"])
        self.assertTrue(stale.exists())
        _, dry = self.check(*HOT, *AGED, "--dry-run")
        self.assertEqual(dry["cleanup"]["wouldDelete"], [stale.name])
        self.assertTrue(stale.exists())

    def test_refuses_shared_or_other_writable_temp_dirs(self):
        shared = self.base / "shared"
        shared.mkdir()
        os.chmod(shared, 0o1777)
        stale = shared / "tron-sync-race-Ab12Cd"
        make_tree(stale)
        age_out()
        for temp in (shared, Path("/tmp")):
            output = self.guard("check", "--sample-seconds", "0.2", *COLD, *AGED, temp=temp, status=2)
            self.assertIn("not a private temp dir", output)
            self.guard("install", "--print-plist", temp=temp, status=2)
        self.assertTrue(stale.exists())
        self.assertFalse((self.home / "Library" / "Logs" / "tron-fsevents-guard.jsonl").exists())

    def test_default_temp_dir_is_this_users_private_darwin_temp_dir(self):
        # Without --temp-dir the guard resolves the per-user Darwin temp dir the
        # way the maintainer runs `install`; a dry run removes nothing.
        expected = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], stdout=subprocess.PIPE,
                                  text=True, check=True).stdout.strip()
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        result = subprocess.run([PYTHON, str(SCRIPT), "install", "--print-plist"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        program = plistlib.loads(result.stdout.encode())["ProgramArguments"]
        self.assertEqual(os.path.realpath(program[4]), os.path.realpath(expected))
        result = subprocess.run([PYTHON, str(SCRIPT), "check", "--dry-run", "--sample-seconds", "0.2", *COLD],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.home / "Library" / "Logs" / "tron-fsevents-guard.jsonl"
        record = json.loads(log.read_text().splitlines()[-1])
        self.assertEqual(record["cleanup"].get("deleted", []), [], record)

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
        age_out()
        # Run the agent's exact program once; COLD keeps the pass from alerting
        # or deferring regardless of the machine's fseventsd.
        result = subprocess.run([PYTHON, *program[1:], "--sample-seconds", "0.2", *COLD, *AGED],
                                env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())
        status = self.guard("status")
        self.assertIn("tron-agent-run-Ab12Cd", status)


if __name__ == "__main__":
    unittest.main()
