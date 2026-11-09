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
            for name in ("gateway.py", "vitest_configs.py"):
                (verify / name).write_text((ROOT / "tools/verify" / name).read_text())
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


class GatewayTestConfigRouting(unittest.TestCase):
    """`scripts/tron test gateway <file>` runs a file listed by a Gateway Vitest config under that config."""

    def run_files(self, base: Path, *words: str):
        (base / "argv").unlink(missing_ok=True)
        result = subprocess.run([sys.executable, str(base / "tools/verify/gateway.py"), *words], cwd=base / "packages/gateway",
                                env={**os.environ, GATEWAY.HELD_BY_CALLER: "1"}, capture_output=True, text=True, timeout=60)
        return result, (base / "argv").read_text() if (base / "argv").exists() else None

    def test_a_listed_file_runs_under_its_own_config_and_a_mixed_list_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            verify = base / "tools/verify"
            verify.mkdir(parents=True)
            for source in (ROOT / "tools/verify").glob("*.py"):
                (verify / source.name).write_text(source.read_text())
            node = base / "scripts/tron-node"  # a stand-in Node, then a Vitest that records its arguments
            node.parent.mkdir()
            node.write_text('#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
            gateway = base / "packages/gateway"
            vitest = gateway / "node_modules/.bin/vitest"
            vitest.parent.mkdir(parents=True)
            vitest.write_text(f'#!/bin/bash\necho "$*" > {base}/argv\n')
            for script in (node, vitest):
                script.chmod(0o755)
            (gateway / "vitest.nested.config.ts").write_text('export const nestedTestFiles = [\n  "src/a/nested.e2e.test.ts",\n];\n')
            (gateway / "vitest.mac-terminal.config.ts").write_text('export const macTerminalTestFiles = ["src/b/terminal.e2e.test.ts"];\n')
            for path in ("src/a/nested.e2e.test.ts", "src/a/plain.test.ts", "src/b/terminal.e2e.test.ts"):
                (gateway / path).parent.mkdir(parents=True, exist_ok=True)
                (gateway / path).write_text("")
            nested, terminal = ["--config", "vitest.nested.config.ts"], ["--config", "vitest.mac-terminal.config.ts"]
            for words, config in ((["src/a/nested.e2e.test.ts"], nested),
                                  (["packages/gateway/src/b/terminal.e2e.test.ts", "-t", "x"], terminal),
                                  ([str(gateway / "src/a/nested.e2e.test.ts:12")], nested),
                                  (["src/a/plain.test.ts"], []), (["plain"], []),
                                  ([*nested, "src/a/nested.e2e.test.ts"], [])):
                with self.subTest(words=words):
                    result, argv = self.run_files(base, *words)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(argv, " ".join(["run", *config, *words]) + "\n")
            # A list spanning configs, including a Vitest substring filter that matches files of two, runs nothing.
            for words in (["src/a/nested.e2e.test.ts", "src/a/plain.test.ts"], ["src/a/"]):
                with self.subTest(words=words):
                    result, argv = self.run_files(base, *words, "-t", "x")
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIsNone(argv, "a mixed list ran Vitest")
                    self.assertIn("scripts/tron test gateway --config vitest.nested.config.ts -t x", result.stderr)
                    self.assertIn("scripts/tron test gateway -t x ", result.stderr)


if __name__ == "__main__":
    unittest.main()
