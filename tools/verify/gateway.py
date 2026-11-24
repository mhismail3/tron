#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from __future__ import annotations
from pathlib import Path
import ctypes
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


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
    files = ('browser-fork-receipts.integration.test.ts', 'home-tool-admission.e2e.test.ts')
    if not any(name in word for word in arguments for name in files):
        return {}
    binary = provision_chrome_for_testing(node)
    return {'AGENT_BROWSER_EXECUTABLE_PATH': str(binary), 'AGENT_BROWSER_ARGS': '--password-store=basic,--use-mock-keychain'}


def named_processes(root: Path) -> list[int]:
    """This user's processes whose arguments or environment (the kernel's KERN_PROCARGS2 block) name a path under `root`."""
    libc = ctypes.CDLL(None)
    listing = subprocess.run(['/usr/bin/pgrep', '-U', str(os.getuid()), '.'], capture_output=True, text=True).stdout
    buffer = ctypes.create_string_buffer(1 << 20)
    found = []
    for pid in (int(word) for word in listing.split()):
        size = ctypes.c_size_t(len(buffer))
        if libc.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buffer, ctypes.byref(size), None, 0):
            continue
        block = buffer.raw[4:size.value]
        if f'{root}/'.encode() in block:
            found.append(pid)
    return found


def reap(root: Path) -> None:
    """SIGKILL every process naming the scratch root until none is left: what a test left running, including children
    re-parented to launchd or moved to their own session, which the caller's process-group kill never reaches."""
    for _ in range(50):
        left = named_processes(root)
        if not left:
            return
        for pid in left:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.1)
    raise SystemExit(f'gateway tests: processes under {root} survived SIGKILL')


def main() -> int:
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    arguments = sys.argv[1:]
    browser = browser_fixture_environment(arguments, node)
    signal.signal(signal.SIGTERM, lambda signum, _frame: sys.exit(128 + signum))
    with tempfile.TemporaryDirectory(prefix="tron-gateway-tests-", dir="/tmp") as temporary:
        root = Path(temporary)
        home, scratch = root / "home", root / "tmp"
        home.mkdir(); scratch.mkdir()
        environment = {**os.environ, **browser, "HOME": str(home), "TMPDIR": str(scratch), "TRON_NODE_BIN": node}
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
                reap(root)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
