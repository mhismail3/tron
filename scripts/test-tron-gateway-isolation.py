#!/usr/bin/env python3
"""Gateway test CLI and actual migration fixture, with a synthetic caller HOME."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GatewayTestHomeIsolation(unittest.TestCase):
    def run_gateway(self, root: Path, arguments: list[str]) -> subprocess.CompletedProcess:
        caller_home = root / "caller-home"
        caller_home.mkdir()
        scratch = root / "scratch"
        scratch.mkdir()
        node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
        env = {**os.environ, "HOME": str(caller_home), "TMPDIR": str(scratch),
               "TRON_NODE_BIN": node, "ISOLATION_CALLER_HOME": str(caller_home)}
        result = subprocess.run([str(ROOT / "scripts/tron"), "test", "gateway", *arguments],
                                cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
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
