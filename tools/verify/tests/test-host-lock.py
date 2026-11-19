#!/usr/bin/env python3
"""The host's full-Gateway lock (`host_lock.py`) through the shipped Gateway runner: waits, arrival order, dead waiters."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]


def shipped_runner(root, lock):
    """The shipped Gateway runner, its config reader and its host lock under `root`, pointed at this test's lock path, not the host's."""
    (root / 'tools/verify').mkdir(parents=True, exist_ok=True)
    defaults = root / 'fixture-node'
    defaults.write_text('#!/bin/sh\nprintf \'["default"]\\n\'\n')
    defaults.chmod(0o755)
    vitest = root / 'packages/gateway/node_modules/vitest'
    vitest.parent.mkdir(parents=True)
    vitest.symlink_to(ROOT / 'packages/gateway/node_modules/vitest', target_is_directory=True)
    for name in ('gateway.py', 'vitest_configs.py', 'ledger.py', 'ledger-host.mjs', 'ledger-vitest.mjs'):
        (root / 'tools/verify' / name).write_text((ROOT / 'tools/verify' / name).read_text())
    source = (ROOT / 'tools/verify/host_lock.py').read_text()
    assert "'/tmp/tron-full-gateway.lock'" in source, 'the host lock path moved; point this fixture at its new spelling'
    (root / 'tools/verify/host_lock.py').write_text(source.replace("'/tmp/tron-full-gateway.lock'", repr(str(lock))))
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-q', '--allow-empty', '-m', 'runner fixture'], check=True)
    return root / 'tools/verify/gateway.py'


def wait_until(predicate, message, timeout=30):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(message)
        time.sleep(0.05)


class GatewayRuns:
    """Shipped Gateway runners pointed at one test lock, in their own scratch directory. Each stand-in
    Vitest appends its test name to `order` once its run holds the lock; a run named holder* keeps
    it until released (or its directory is gone, so an orphan of a killed runner still ends)."""

    def __init__(self, lock: Path):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-runs-')
        self.ledger = tempfile.TemporaryDirectory(prefix='tron-gateway-ledger-')
        directory = Path(self.temporary.name)
        self.directory, self.order, self.runs = directory, directory / 'order', {}
        self.gateway = shipped_runner(directory, lock)
        node = directory / 'scripts/tron-node'
        node.parent.mkdir()
        node.write_text(f'#!/bin/bash\n[[ $# == 0 ]] && {{ echo {directory / "fixture-node"}; exit 0; }}\nshift; exec "$@"\n')
        vitest = directory / 'packages/gateway/node_modules/.bin/vitest'
        vitest.parent.mkdir(parents=True)
        vitest.write_text(f'#!/bin/bash\necho "$2" >> {self.order}\n'
                          f'while [[ "$2" == holder* && ! -e {directory}/release-$2 && -d {directory} ]]; do sleep 0.05; done\n')
        for script in (node, vitest):
            script.chmod(0o755)

    def start(self, name):
        inherited = {key: value for key, value in os.environ.items() if key != 'TRON_FULL_GATEWAY_LOCK_HELD'}
        with (self.directory / f'{name}.err').open('w') as stderr:
            self.runs[name] = subprocess.Popen(['python3', str(self.gateway), name],
                                               env={**inherited, 'TRON_TEST_LEDGER': str(Path(self.ledger.name) / 'results.sqlite3')},
                                               stdout=subprocess.DEVNULL, stderr=stderr)
        return self.runs[name]

    def stderr(self, name):
        return (self.directory / f'{name}.err').read_text()

    def names(self):
        lines = self.order.read_text().split() if self.order.exists() else []
        return list(dict.fromkeys(lines))

    def wait_holding(self, name):
        wait_until(lambda: name in self.names(), f'{name} never held the lock: {self.stderr(name)}')

    def wait_queued(self, name):
        wait_until(lambda: 'waiting for' in self.stderr(name), f'{name} never queued: {self.stderr(name)}')

    def release(self, name):
        (self.directory / f'release-{name}').touch()

    def wait_all(self, names=None):
        for name in names or self.runs:
            self.runs[name].wait(timeout=60)
            if self.runs[name].returncode != -signal.SIGKILL:
                assert self.runs[name].returncode == 0, (name, self.stderr(name))

    def close(self):
        for name, run in self.runs.items():
            self.release(name)
            if run.poll() is None:
                run.terminate()
                run.wait(timeout=30)
        self.temporary.cleanup()
        self.ledger.cleanup()


class FullGatewayLockTests(unittest.TestCase):
    """A Gateway Vitest run waits for the host's full-Gateway lock, so it never overlaps another
    full-Gateway run; a run whose caller already holds it (`mutate`) runs without waiting."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-lock-')
        root = Path(self.temporary.name)
        self.lock = root / 'full-gateway.lock'
        self.ran = root / 'ran'
        shipped_runner(root, self.lock)
        (root / 'scripts').mkdir()
        (root / 'scripts/tron-node').write_text(f'#!/bin/bash\n[[ $# == 0 ]] && {{ echo {root / "fixture-node"}; exit 0; }}\nshift; exec "$@"\n')
        vitest = root / 'packages/gateway/node_modules/.bin/vitest'
        vitest.parent.mkdir(parents=True)
        vitest.write_text(f'#!/bin/bash\necho "$@" >> {self.ran}\n')
        for script in (root / 'scripts/tron-node', vitest):
            script.chmod(0o755)
        self.gateway = root / 'tools/verify/gateway.py'

    def tearDown(self):
        self.temporary.cleanup()

    def start(self, env=None, stderr=subprocess.PIPE):
        ledger = tempfile.TemporaryDirectory(prefix='tron-gateway-ledger-')
        self.addCleanup(ledger.cleanup)
        inherited = {key: value for key, value in os.environ.items() if key != 'TRON_FULL_GATEWAY_LOCK_HELD'}
        return subprocess.Popen(['python3', str(self.gateway), 'some.test.ts'], env={**inherited, **(env or {}), 'TRON_TEST_LEDGER': str(Path(ledger.name) / 'results.sqlite3')},
                                stdout=subprocess.PIPE, stderr=stderr, text=True)

    def test_a_run_waits_for_the_held_lock_then_records_itself(self):
        import fcntl
        errors = Path(self.temporary.name) / 'stderr'
        with self.lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with errors.open('w') as sink:
                run = self.start(stderr=sink)
                wait_until(lambda: 'waiting for ' in errors.read_text(), 'the run to announce that it waits')
                held_until = time.monotonic() + 2
                while time.monotonic() < held_until:
                    self.assertIsNone(run.poll(), 'the run waits while another holder has the lock')
                    self.assertFalse(self.ran.exists(), 'Vitest does not start before the lock is free')
                    time.sleep(0.05)
        out, _ = run.communicate(timeout=30)
        err = errors.read_text()
        self.assertEqual(run.returncode, 0, out + err)
        self.assertIn('waiting for ' + str(self.lock), err)
        self.assertEqual(self.ran.read_text().split(), ['run', 'some.test.ts', '--reporter=default',
                         '--reporter=' + str(self.gateway.with_name('ledger-vitest.mjs').resolve())])
        self.assertIn('"purpose": "gateway vitest some.test.ts"', self.lock.read_text())

    def test_a_run_whose_caller_holds_the_lock_runs_without_waiting(self):
        import fcntl
        with self.lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            run = self.start({'TRON_FULL_GATEWAY_LOCK_HELD': '1'})
            out, err = run.communicate(timeout=30)
        self.assertEqual(run.returncode, 0, out + err)
        self.assertTrue(self.ran.exists())


class FullGatewayLockQueueTests(unittest.TestCase):
    """Full-Gateway lock waiters take it in arrival order, and a dead waiter or holder never wedges the line."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tron-gateway-queue-')
        self.addCleanup(self.temporary.cleanup)
        self.runs = GatewayRuns(Path(self.temporary.name) / 'full-gateway.lock')
        self.addCleanup(self.runs.close)

    def test_runs_take_the_lock_in_arrival_order(self):
        self.runs.start('holder')
        self.runs.wait_holding('holder')
        for name in ('first', 'second', 'third'):
            self.runs.start(name)
            self.runs.wait_queued(name)
        self.runs.release('holder')
        self.runs.wait_all()
        self.assertEqual(self.runs.names(), ['holder', 'first', 'second', 'third'])

    def test_a_killed_waiter_and_a_killed_holder_lose_their_places(self):
        holder = self.runs.start('holder')
        self.runs.wait_holding('holder')
        doomed = self.runs.start('doomed')
        self.runs.wait_queued('doomed')
        doomed.kill()
        doomed.wait(timeout=30)
        self.runs.start('after')
        self.runs.wait_queued('after')
        holder.kill()
        holder.wait(timeout=30)
        self.runs.wait_all(['after'])
        self.assertEqual(self.runs.names(), ['holder', 'after'])
        self.runs.start('fresh')
        self.runs.wait_all(['fresh'])
        self.assertNotIn('waiting for', self.runs.stderr('fresh'))
        self.assertEqual(self.runs.names(), ['holder', 'after', 'fresh'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
