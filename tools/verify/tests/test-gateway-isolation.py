#!/usr/bin/env python3
"""Gateway test CLI and actual migration fixture, with a synthetic caller HOME and TMPDIR."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]


def fixture_node(node: Path) -> None:
    defaults = node.with_name('fixture-node')
    defaults.write_text('#!/bin/sh\nprintf \'["default"]\\n\'\n')
    defaults.chmod(0o755)
    node.write_text(f'#!/bin/bash\n[[ $# == 0 ]] && {{ echo {defaults}; exit 0; }}\nshift; exec "$@"\n')


def commit_fixture(root: Path) -> None:
    for arguments in (['init', '-q'], ['add', '-A'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']):
        subprocess.run(['git', '-C', str(root), *arguments], check=True, capture_output=True)


class GatewayTestHomeIsolation(unittest.TestCase):
    def run_gateway(self, root: Path, arguments: list[str]) -> subprocess.CompletedProcess:
        caller_home = root / "caller-home"
        caller_home.mkdir()
        scratch = root / "scratch" / ("caller-tmpdir-" * 5)
        scratch.mkdir(parents=True)
        node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
        env = {**os.environ, "HOME": str(caller_home), "TMPDIR": str(scratch),
               "TRON_NODE_BIN": node, "ISOLATION_CALLER_HOME": str(caller_home),
               "ISOLATION_CALLER_TMPDIR": str(scratch)}
        result = subprocess.run([str(ROOT / "scripts/tron"), "test", "gateway", *arguments],
                                cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        evidence = ROOT / "test-results/gateway-home-isolation"
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / (self._testMethodName + ".log")).write_text(result.stdout)
        return result

    def test_cli_test_process_cannot_resolve_the_callers_home(self):
        with tempfile.TemporaryDirectory(prefix="tron-home-contract-") as temporary:
            root = Path(temporary)
            config = root / "vitest.config.mjs"
            config.write_text("export default {test:{globals:true,include:['probe.test.mjs'],maxWorkers:1}};\n")
            (root / "probe.test.mjs").write_text('''import {homedir} from 'node:os';
import {resolve,relative,isAbsolute} from 'node:path';
import {writeFileSync,readFileSync} from 'node:fs';
test('HOME resolution and filesystem writes stay outside caller HOME',()=>{
 const path=resolve(homedir(),'.tron','agent','settings.json');
 const fromCaller=relative(process.env.ISOLATION_CALLER_HOME,path);
 expect(fromCaller.startsWith('..') || isAbsolute(fromCaller)).toBe(true);
 const owned=resolve(homedir(),'owned-marker');
 writeFileSync(owned,'synthetic fixture');
 expect(readFileSync(owned,'utf8')).toBe('synthetic fixture');
 expect(process.env.TMPDIR).not.toBe(process.env.HOME);
 const fromCallerTmp=relative(process.env.ISOLATION_CALLER_TMPDIR,process.env.TMPDIR);
 expect(fromCallerTmp.startsWith('..') || isAbsolute(fromCallerTmp)).toBe(true);
});
''')
            result = self.run_gateway(root, ["--root", str(root), "--config", str(config)])
            self.assertEqual(result.returncode, 0, result.stdout[-5000:])
            self.assertFalse((root / "caller-home/owned-marker").exists())

    def test_actual_settings_fixture_needs_no_caller_home_stores(self):
        with tempfile.TemporaryDirectory(prefix="tron-settings-home-contract-") as temporary:
            root = Path(temporary)
            result = self.run_gateway(root, ["src/e2e/admin/native-change.e2e.test.ts", "-t",
                                            "applies a reversible routine edit"])
            self.assertEqual(result.returncode, 0, result.stdout[-5000:])
            self.assertFalse((root / "caller-home/.tron").exists())


class GatewayTestScratchCleanup(unittest.TestCase):
    def test_a_group_sigterm_mid_run_removes_the_scratch_root(self) -> None:
        """A SIGTERM mid-run removes the scratch root."""
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            verify = base / "tools/verify"
            verify.mkdir(parents=True)
            (verify / "gateway.py").write_text((ROOT / "tools/verify/gateway.py").read_text())
            node = base / "scripts/tron-node"
            node.parent.mkdir()
            fixture_node(node)
            vitest = base / "packages/gateway/node_modules/.bin/vitest"
            vitest.parent.mkdir(parents=True)
            vitest.write_text(f'#!/bin/bash\necho "$HOME" > {base}/home\nsleep 60 & wait\n')
            for script in (node, vitest):
                script.chmod(0o755)
            commit_fixture(base)
            runner = subprocess.Popen([sys.executable, str(verify / "gateway.py"), "x.test.ts"],
                                      stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 30
            while not (base / "home").exists() or not (base / "home").read_text().strip():
                self.assertLess(time.monotonic(), deadline, "the runner never started Vitest")
                time.sleep(0.05)
            root = Path((base / "home").read_text().strip()).parent
            self.assertTrue(root.name.startswith("tron-gateway-tests-") and root.is_dir(), root)
            os.killpg(runner.pid, signal.SIGTERM)
            runner.wait(timeout=30)
            self.assertFalse(root.exists(), "a SIGTERMed run left its scratch root")


class GatewayTestOrphanReaping(unittest.TestCase):
    def test_a_test_process_left_in_its_own_session_is_reaped_before_the_runner_returns(self) -> None:
        """A test process in its own process group escapes the caller's group kill; the runner reaps it by its scratch root (#2648)."""
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            verify = base / "tools/verify"
            verify.mkdir(parents=True)
            (verify / "gateway.py").write_text((ROOT / "tools/verify/gateway.py").read_text())
            node = base / "scripts/tron-node"
            node.parent.mkdir()
            fixture_node(node)
            vitest = base / "packages/gateway/node_modules/.bin/vitest"
            vitest.parent.mkdir(parents=True)
            vitest.write_text(f"#!/bin/bash\necho \"$TMPDIR\" > {base}/scratch\n"
                              "/usr/bin/perl -e 'exit if fork; setpgrp(0, 0); exec {\"/bin/sleep\"} \"$ENV{TMPDIR}/driver.cjs\", \"300\"' </dev/null >/dev/null 2>&1\n")
            for script in (node, vitest):
                script.chmod(0o755)
            commit_fixture(base)
            subprocess.run([sys.executable, str(verify / "gateway.py"), "x.test.ts"], capture_output=True, timeout=60)
            root = str(Path((base / "scratch").read_text().strip()).parent)
            listing = subprocess.run(["/bin/ps", "-U", str(os.getuid()), "-ww", "-E", "-o", "pid=,command="], capture_output=True, text=True).stdout
            left = [line for line in listing.splitlines() if root + "/" in line]
            for line in left:
                os.kill(int(line.split()[0]), signal.SIGKILL)
            self.assertEqual(left, [])


if __name__ == "__main__":
    unittest.main()
