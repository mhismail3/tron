#!/usr/bin/env python3
"""Gateway test CLI and actual migration fixture, with a synthetic caller HOME and TMPDIR."""
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
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
            result = self.run_gateway(root, ["src/admin/native-change.e2e.test.ts", "-t",
                                            "applies a reversible routine edit"])
            self.assertEqual(result.returncode, 0, result.stdout[-5000:])
            self.assertFalse((root / "caller-home/.tron").exists())


if __name__ == "__main__":
    unittest.main()
