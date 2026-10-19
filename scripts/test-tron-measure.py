#!/usr/bin/env python3
"""V10 real CLI/Git fixture: moves, indentation, rewrites and single-use matching."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "test-results/measure-cli"


class MeasureTests(unittest.TestCase):
    def test_move_rewrite_and_deterministic_committed_report(self):
        with tempfile.TemporaryDirectory(prefix="tron-measure-") as temp:
            repo = Path(temp) / "repo"
            repo.mkdir()
            env = {**os.environ, "HOME": temp, "TMPDIR": temp, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": os.devnull, "GIT_AUTHOR_NAME": "Fixture", "GIT_COMMITTER_NAME": "Fixture",
                   "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True).stdout.strip()
            def write(path, content):
                target = repo / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            def call(*args):
                return subprocess.run([str(repo / "scripts/tron"), "measure", *args], cwd=repo, env=env,
                                      capture_output=True, text=True, timeout=30)
            for path in ("scripts/tron", "tools/metrics/metrics.py", "tools/metrics/moved.py"):
                write(path, (ROOT / path).read_bytes())
            (repo / "scripts/tron").chmod(0o755)
            git("init", "-q", "-b", "main")
            block = b"".join(f"unique moved line {i}\n".encode() for i in range(12))
            write("old name.txt", block)
            write("rewrite.txt", b"before rewrite\n")
            write("source.txt", b"cross file one\ncross file two\n")
            write("duplicates.txt", b"duplicate\nduplicate\n")
            write("binary.bin", b"\0old")
            git("add", "."); git("commit", "-qm", "base")
            initial = git("rev-parse", "HEAD")
            git("update-index", "--add", "--cacheinfo", f"160000,{initial},gitlink")
            git("commit", "-qm", "base gitlink")
            base = git("rev-parse", "HEAD")
            git("update-index", "--cacheinfo", f"160000,{base},gitlink")
            git("mv", "old name.txt", "new\tname.txt")
            write("new\tname.txt", block.replace(b"unique moved line 0", b"    unique moved line 0").replace(
                b"unique moved line 11", b"changed within rename"))
            write("rewrite.txt", b"after rewrite\n")
            git("rm", "source.txt", "duplicates.txt")
            write("destination.txt", b"  cross file one\n\tcross file two\n")
            write("one-duplicate.txt", b"duplicate\n")
            write("brand-new.txt", b"genuinely new\n")
            write("binary.bin", b"\0new")
            git("add", "."); git("commit", "-qm", "move and rewrite")
            head = git("rev-parse", "HEAD")
            result = call(base, head)
            self.assertEqual(result.returncode, 0, result.stderr)
            output = repo / "test-results/measure" / f"{base}-{head}.json"
            data = json.loads(output.read_text())
            rows = {row["path"]: row for row in data["files"]}
            self.assertEqual(rows["new\tname.txt"]["status"], "R")
            self.assertEqual(rows["new\tname.txt"]["moved"], 11)
            self.assertEqual(rows["new\tname.txt"]["changedInMove"], 1)
            self.assertEqual(rows["rewrite.txt"]["rewritten"], 1)
            self.assertEqual(rows["destination.txt"]["moved"], 2)
            self.assertEqual(rows["source.txt"]["movedOut"], 2)
            self.assertEqual(rows["one-duplicate.txt"]["moved"], 1)
            self.assertEqual(rows["one-duplicate.txt"]["deleted"], 1)
            self.assertEqual(rows["brand-new.txt"]["new"], 1)
            self.assertTrue(rows["binary.bin"]["binaryOrGitlink"])
            self.assertTrue(rows["gitlink"]["binaryOrGitlink"])
            self.assertEqual(data["totals"], {"moved": 14, "movedOut": 14, "rewritten": 2,
                                              "changedInMove": 1, "new": 1, "deleted": 1})
            original = output.read_bytes()
            write("rewrite.txt", b"uncommitted noise\n")
            self.assertEqual(call(base).returncode, 0)
            self.assertEqual(original, output.read_bytes())
            bad = call("missing-revision")
            self.assertEqual(bad.returncode, 2)
            self.assertIn("unknown revision", bad.stderr)
            self.assertEqual(len(list(output.parent.glob("*.json"))), 1)
            ARTIFACT.mkdir(parents=True, exist_ok=True)
            (ARTIFACT / "report.json").write_bytes(original)
            (ARTIFACT / "run.txt").write_text(result.stdout + bad.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
