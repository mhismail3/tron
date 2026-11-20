#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from __future__ import annotations
from pathlib import Path
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_lock import FULL_GATEWAY_LOCK, HELD_BY_CALLER, wait_for_lock  # noqa: E402  (the one host lock owner)
from vitest_configs import Refused, filter_selects, vitest_selection, with_own_config  # noqa: E402  (the one Vitest selection classifier)
import ledger


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting its turn behind any holder and earlier waiters; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    record = {'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}
    return wait_for_lock(FULL_GATEWAY_LOCK, record, lambda line: print(f'gateway tests: {line}', file=sys.stderr, flush=True))


def provision_chrome_for_testing(node: str) -> Path:
    """The Chrome for Testing binary the pinned engine's own installer fetched into this clone's shared verify state, once."""
    engine = ROOT / 'packages/gateway/node_modules/agent-browser'
    version = json.loads((engine / 'package.json').read_text())['version']
    clean = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    common = Path(subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                          text=True, env=clean).strip())
    fixtures = common / 'verify/fixtures'
    fixtures.mkdir(parents=True, exist_ok=True)
    target = fixtures / f'chrome-for-testing-agent-browser-{version}'
    stamp = target / '.tron-provisioned'
    with open(fixtures / 'chrome-for-testing.lock', 'a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if stamp.is_file() and (target / stamp.read_text()).is_file():
            return target / stamp.read_text()
        print(f'gateway tests: provisioning Chrome for Testing with the pinned agent-browser {version} installer into {target}',
              file=sys.stderr, flush=True)
        for stale in fixtures.glob('.chrome-for-testing-*'):
            shutil.rmtree(stale, ignore_errors=True)
        staging = Path(tempfile.mkdtemp(prefix='.chrome-for-testing-', dir=fixtures))
        try:
            subprocess.run([node, str(engine / 'bin/agent-browser.js'), 'install'], cwd=staging, check=True, timeout=900,
                           stdout=sys.stderr, env={'PATH': clean.get('PATH', '/usr/bin:/bin'), 'HOME': str(staging)})
            binaries = sorted(staging.glob('.agent-browser/browsers/chrome-*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'))
            if len(binaries) != 1:
                raise SystemExit(f'gateway tests: the agent-browser {version} installer produced {len(binaries)} Chrome for Testing binaries')
            (staging / '.tron-provisioned').write_text(str(binaries[0].relative_to(staging)))
            shutil.rmtree(target, ignore_errors=True)
            os.rename(staging, target)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
    return target / stamp.read_text()


def browser_fixture_environment(arguments: list[str], node: str) -> dict[str, str]:
    files = ('src/e2e/sessions/browser-fork-receipts.integration.test.ts', 'src/e2e/automations/home-tool-admission.e2e.test.ts')
    config, filters = vitest_selection(arguments, ROOT / 'packages/gateway')
    if config not in (None, 'vitest.config.ts'):
        return {}
    if filters and not any(filter_selects(relative, path) for _, relative in filters for path in files):
        return {}
    if not any((ROOT / 'packages/gateway' / path).is_file() for path in files):
        return {}
    binary = provision_chrome_for_testing(node)
    if not binary.is_file():
        raise SystemExit('Gateway browser fixtures require cached Chrome for Testing; no personal browser fallback')
    return {'AGENT_BROWSER_EXECUTABLE_PATH': str(binary), 'AGENT_BROWSER_ARGS': '--password-store=basic,--use-mock-keychain'}


def main() -> int:
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    try:
        arguments = with_own_config(sys.argv[1:], ROOT / 'packages/gateway')
    except Refused as refusal:
        print(refusal, file=sys.stderr)
        return 2
    browser = browser_fixture_environment(arguments, node)
    lock = hold_full_gateway_lock()
    capture = ledger.Capture('gateway-nested' if 'vitest.nested.config.ts' in arguments else 'gateway')
    signal.signal(signal.SIGTERM, lambda signum, _frame: sys.exit(128 + signum))
    with tempfile.TemporaryDirectory(prefix="tron-gateway-tests-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, scratch = root / "home", root / "tmp"
        home.mkdir(); scratch.mkdir()
        report = root / 'cases.jsonl'
        environment = {**os.environ, **browser, "HOME": str(home), "TMPDIR": str(scratch), "TRON_NODE_BIN": node,
                       'TRON_TEST_LEDGER_CASES': str(report), 'TRON_TEST_LEDGER_CPU_IDLE': str(capture.context['cpuIdlePercent'])}
        if not any(word.startswith('--reporter') for word in arguments):
            defaults = subprocess.check_output([node, '-p', "JSON.stringify(require('vitest/config').configDefaults.reporters)"],
                                               cwd=ROOT / 'packages/gateway', env=environment, text=True)
            arguments.extend('--reporter=' + reporter for reporter in json.loads(defaults))
        arguments.append('--reporter=' + str(ROOT / 'tools/verify/ledger-vitest.mjs'))
        with subprocess.Popen([str(ROOT / "scripts/tron-node"), "exec", str(vitest), "run", *arguments],
                              cwd=ROOT / "packages/gateway", env=environment) as child:
            def forward(signum, _frame):
                if child.poll() is None:
                    child.send_signal(signum)
            previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT)}
            try:
                return child.wait()
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                try:
                    capture.events(report)
                finally:
                    if lock:
                        lock.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
