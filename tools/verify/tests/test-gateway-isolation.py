#!/usr/bin/env python3
"""Gateway test CLI and actual migration fixture, with a synthetic caller HOME and TMPDIR."""
from pathlib import Path
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("tron_gateway_runner", ROOT / "tools/verify/gateway.py")
GATEWAY = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(GATEWAY)


class GatewayTestHomeIsolation(unittest.TestCase):
    def run_gateway(self, root: Path, arguments: list[str]) -> subprocess.CompletedProcess:
        caller_home = root / "caller-home"
        caller_home.mkdir()
        # A long caller TMPDIR, like a Home task worker's (#2260): the suite's scratch must not live under it.
        scratch = root / "scratch" / ("caller-tmpdir-" * 5)
        scratch.mkdir(parents=True)
        node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
        env = {**os.environ, "HOME": str(caller_home), "TMPDIR": str(scratch),
               "TRON_NODE_BIN": node, "ISOLATION_CALLER_HOME": str(caller_home),
               "ISOLATION_CALLER_TMPDIR": str(scratch)}
        # The runner waits for the host's full-Gateway lock without a bound; take it here first
        # through the runner's own owner (waiting likewise, recording this holder) so the bound
        # below covers only this run, which then holds it.
        lock = GATEWAY.hold_full_gateway_lock()
        try:
            result = subprocess.run([str(ROOT / "scripts/tron"), "test", "gateway", *arguments],
                                    cwd=ROOT, env={**env, GATEWAY.HELD_BY_CALLER: "1"}, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        finally:
            if lock:
                lock.close()
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
        """What verify, batch, probe and mutate send first: the root goes, so nothing needs a reaper."""
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            verify = base / "tools/verify"
            verify.mkdir(parents=True)
            (verify / "gateway.py").write_text((ROOT / "tools/verify/gateway.py").read_text())
            lock = (ROOT / "tools/verify/host_lock.py").read_text()
            self.assertIn("'/tmp/tron-full-gateway.lock'", lock)
            (verify / "host_lock.py").write_text(lock.replace("'/tmp/tron-full-gateway.lock'", repr(str(base / "full.lock"))))
            node = base / "scripts/tron-node"  # a stand-in Node, then a Vitest that records HOME and waits
            node.parent.mkdir()
            node.write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
            vitest = base / "packages/gateway/node_modules/.bin/vitest"
            vitest.parent.mkdir(parents=True)
            vitest.write_text(f'#!/bin/bash\necho "$HOME" > {base}/home\nsleep 60 & wait\n')
            for script in (node, vitest):
                script.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if key != GATEWAY.HELD_BY_CALLER}
            runner = subprocess.Popen([sys.executable, str(verify / "gateway.py"), "x.test.ts"], env=env,
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


if __name__ == "__main__":
    unittest.main()
