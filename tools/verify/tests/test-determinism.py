#!/usr/bin/env python3
"""Exercise the determinism lint's CLI in an isolated repository: new sites fail, fixed sites tighten, the baseline never grows."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "determinism.py"
CLEAN = 'it("a", async () => { await waitFor(() => true, "x"); });\n'
SLEEPY = 'it("a", async () => { await new Promise(resolve => setTimeout(resolve, 10)); }, 5_000);\nit.only("b", () => {});\n'


class DeterminismTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "tools/verify").mkdir(parents=True)
        shutil.copy(SCRIPT, self.root / "tools/verify/determinism.py")
        self.test = self.root / "packages/gateway/src/a.test.ts"
        self.test.parent.mkdir(parents=True)
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.git("commit", "-q", "--allow-empty", "-m", "base")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def lint(self, *args):
        return subprocess.run(["python3", str(self.root / "tools/verify/determinism.py"), "--base", "HEAD", *args],
                              cwd=self.root, capture_output=True, text=True)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "c")

    def test_new_sites_fail_and_fixed_sites_tighten_only(self):
        self.test.write_text(SLEEPY)
        self.assertEqual(self.lint("--update").returncode, 0)
        self.commit()
        self.assertEqual(self.lint().returncode, 0)
        self.test.write_text(SLEEPY + SLEEPY)
        grown = self.lint()
        self.assertEqual(grown.returncode, 1)
        for rule in ("sleep", "timeout-literal", "skip-only"):
            self.assertIn(f"new site (tools/verify/README.md determinism): {rule}: packages/gateway/src/a.test.ts", grown.stdout)
        self.assertEqual(self.lint("--update").returncode, 1)
        self.test.write_text(CLEAN)
        improved = self.lint()
        self.assertEqual(improved.returncode, 1)
        self.assertIn("improved, tighten the baseline", improved.stdout)
        self.assertEqual(self.lint("--update").returncode, 0)
        self.assertEqual(self.lint().returncode, 0)
        self.commit()
        self.test.write_text(SLEEPY)
        (self.root / "packages/gateway/determinism-baseline.json").write_text(
            '{"sites": {"src/a.test.ts": {"sleep": 1, "timeout-literal": 1, "skip-only": 1}}}')
        widened = self.lint()
        self.assertEqual(widened.returncode, 1)
        self.assertIn("baseline grew past HEAD: sleep", widened.stdout)


if __name__ == "__main__":
    unittest.main()
