#!/usr/bin/env python3
"""The one admission to main: merge, check and push within one end-to-end deadline (tools/verify/README.md)."""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shutil
import uuid
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
DEADLINE = 58.0
STEP = 45.0
TOKEN = 'TRON_GATE_CHECKED_SHA'
GATEWAY_TESTS = [
    'src/admin/auth-broker.integration.test.ts',
    'src/admin/inert-pi-fields-migration.integration.test.ts',
    'src/admin/observed-git-residue-migration.integration.test.ts',
    'src/automations/schedule.test.ts',
    'src/e2e/admin/settings-subject-audit.e2e.test.ts',
    'src/e2e/automations/automations.owned-run.lock.integration.test.ts',
    'src/e2e/automations/schedule-run-now-stop-drain.integration.test.ts',
    'src/e2e/modules/home/home-profile-v2-recovery.integration.test.ts',
    'src/e2e/modules/home/home-task-tool-interrupt.e2e.test.ts',
    'src/e2e/modules/home/home-task-tool-stop.e2e.test.ts',
    'src/e2e/modules/home/home-task-tool-wire.e2e.test.ts',
    'src/e2e/modules/home/home.lock.integration.test.ts',
    'src/e2e/protocol/protocol.wire.lock.integration.test.ts',
    'src/e2e/sessions/pi-persisted-state-corpus.integration.test.ts',
    'src/e2e/sessions/run-queue.lock.integration.test.ts',
    'src/e2e/sessions/run.lock.integration.test.ts',
    'src/e2e/sessions/sdk-behavior-trace.integration.test.ts',
    'src/e2e/sessions/session-search.privacy.lock.integration.test.ts',
    'src/e2e/transport/server-revocation.integration.test.ts',
    'src/modules/home/home-ledger-crash.e2e.test.ts',
    'src/modules/home/home-receipt-crash.e2e.test.ts',
    'src/notifications/push-policy-migration.integration.test.ts',
    'src/sessions/extension-artifact-discovery.integration.test.ts',
    'src/transport/command-receipts.lock.integration.test.ts',
]
PROCESS_TESTS = [
    'src/e2e/kernel/delegation/managed-run-stop-drain.e2e.test.ts',
    'src/e2e/transport/gateway-process-prompt.e2e.test.ts',
    'src/e2e/transport/gateway-process-restart.e2e.test.ts',
    'src/lifecycle/exit-after-shutdown.e2e.test.ts',
]


class Refused(Exception):
    pass


def clean_environment(**extra: str) -> dict:
    return {**{key: value for key, value in os.environ.items() if not key.startswith('GIT_')}, **extra}


class Gate:
    def __init__(self, root: Path, deadline: float = DEADLINE, step: float = STEP, started: float | None = None):
        self.root = root
        self.started = time.monotonic() if started is None else started
        self.deadline = self.started + deadline
        self.step = step
        self.output = root / 'test-results' / 'gate' / f"{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.output.mkdir(parents=True, exist_ok=True)
        self.steps: list[dict] = []
        self.running: list[subprocess.Popen] = []
        self.streams: list = []
        self.cleanup: list[Path] = []

    def left(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Refused(f'the {DEADLINE:.0f}s end-to-end deadline expired')
        return left

    def run(self, command: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(command, cwd=cwd or self.root, env=env or clean_environment(), text=True,
                              capture_output=True, timeout=min(15, self.left()))

    def git(self, *arguments: str, cwd: Path | None = None, env: dict | None = None) -> str:
        result = self.run(['git', *arguments], cwd=cwd, env=env)
        if result.returncode:
            raise Refused(f'git {" ".join(arguments)} failed: {result.stderr.strip()}')
        return result.stdout.strip()

    def parallel(self, commands: list[tuple[str, list[str], Path]], env: dict) -> None:
        pending = []
        for name, command, cwd in commands:
            stream = (self.output / f'{name}.log').open('wb')
            self.streams.append(stream)
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            self.running.append(process)
            pending.append((name, process, stream, time.monotonic()))
        while pending:
            self.left()
            for item in list(pending):
                name, process, stream, began = item
                elapsed = time.monotonic() - began
                code = process.poll()
                if code is None:
                    if elapsed > self.step:
                        raise Refused(f'{name} exceeded its {self.step:.0f}s budget')
                    continue
                stream.close()
                pending.remove(item)
                self.steps.append({'name': name, 'seconds': round(elapsed, 2), 'code': code})
                print(f'gate: {name} {"ok" if code == 0 else f"failed {code}"} {elapsed:.1f}s', flush=True)
                if code:
                    raise Refused(f'{name} failed; see {self.output / (name + ".log")}')
            time.sleep(0.05)

    def stop(self) -> None:
        for process in self.running:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait()
        self.running.clear()
        for stream in self.streams:
            stream.close()
        self.streams.clear()

    def hold(self) -> None:
        """One gate per clone at a time: every worktree shares the common Git directory, so overlapping gates refuse."""
        common = Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir'))
        self.lock = os.open(common / 'tron-gate.lock', os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = os.pread(self.lock, 4096, 0).decode(errors='replace').strip() or 'unknown'
            raise Refused(f'another gate is running ({holder}); rerun when it finishes') from None
        os.ftruncate(self.lock, 0)
        os.pwrite(self.lock, f'pid {os.getpid()} in {self.root}'.encode(), 0)

    def admit(self, checks, tip: str | None = None, push: str = 'push', remote: str = 'origin') -> int:
        outcome, reason, base, merged = 'refused', '', None, None
        pushing = False
        self.lock = None
        tree = Path(tempfile.mkdtemp(prefix='tron-gate-'))
        try:
            self.hold()
            if tip is None:
                if self.git('status', '--porcelain'):
                    raise Refused('commit or remove every change first; the gate admits only committed work')
                tip = self.git('rev-parse', 'HEAD')
            self.git('fetch', '--quiet', '--no-tags', remote, 'refs/heads/main')
            base = self.git('rev-parse', 'FETCH_HEAD')
            self.git('worktree', 'add', '--quiet', '--detach', str(tree), base)
            if push == 'pre-push':
                if self.run(['git', 'merge-base', '--is-ancestor', base, tip]).returncode:
                    raise Refused(f'the pushed commit does not contain {remote}/main; run scripts/tron gate')
                self.git('checkout', '--quiet', '--detach', tip, cwd=tree)
            elif base != tip:
                self.git('merge', '--quiet', '--no-ff', '--no-edit', tip, cwd=tree)
            merged = self.git('rev-parse', 'HEAD', cwd=tree)
            checks(self, tree, base, merged)
            if push == 'push':
                pushing = True
                self.git('push', '--quiet', remote, f'{merged}:refs/heads/main', env=clean_environment(**{TOKEN: merged}))
                outcome = 'updated'
            elif push == 'check':
                self.git('push', '--dry-run', '--quiet', remote, f'{merged}:refs/heads/main', env=clean_environment(**{TOKEN: merged}))
                outcome = 'checked'
            else:
                outcome = 'admitted'
        except (Refused, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
            reason = str(error)
            if pushing:
                outcome = 'outcome-unknown'
                reason += f'; main may have moved: compare {remote}/main with {merged}'
        finally:
            self.stop()
            if self.lock is not None:
                os.close(self.lock)
            try:
                subprocess.run(['git', 'worktree', 'remove', '--force', str(tree)], cwd=self.root, env=clean_environment(),
                               capture_output=True, timeout=10)
            except subprocess.TimeoutExpired:
                pass
            for path in [tree, *self.cleanup]:
                shutil.rmtree(path, ignore_errors=True)
            receipt = {'outcome': outcome, 'reason': reason, 'base': base, 'tip': tip, 'merged': merged,
                       'seconds': round(time.monotonic() - self.started, 2), 'steps': self.steps}
            (self.output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
            print(f'gate: {outcome} in {receipt["seconds"]}s' + (f': {reason}' if reason else '')
                  + (f' (main {merged})' if outcome == 'updated' else '') + f'; {self.output}', flush=True)
        return 0 if outcome in ('updated', 'checked', 'admitted') else 1


def checks(gate: Gate, tree: Path, base: str, merged: str) -> None:
    modules = gate.root / 'packages/gateway/node_modules'
    if not modules.is_dir():
        raise Refused(f'missing {modules}; install Gateway dependencies in this checkout first')
    (tree / 'packages/gateway/node_modules').symlink_to(modules)
    installed = json.loads((modules / '.package-lock.json').read_text())['packages']
    locked = json.loads((tree / 'packages/gateway/package-lock.json').read_text())['packages']
    stale = [name for name, entry in locked.items() if name and not entry.get('optional')
             and installed.get(name, {}).get('version') != entry.get('version')]
    if stale:
        raise Refused(f'installed Gateway dependencies differ from the merged lockfile ({stale[0]}); reinstall first')
    node = gate.run([str(tree / 'scripts/tron-node')]).stdout.strip()
    if not node:
        raise Refused('no pinned Node; see scripts/tron-node')
    home = Path(tempfile.mkdtemp(prefix='tron-gate-home-'))
    gate.cleanup.append(home)
    env = clean_environment(HOME=str(home), TMPDIR=str(home), PYTHONDONTWRITEBYTECODE='1', CI='1',
               PATH=str(Path(node).parent) + os.pathsep + os.environ['PATH'])
    gateway = tree / 'packages/gateway'
    vitest = [node, 'node_modules/vitest/vitest.mjs', 'run', '--reporter=dot', '--allowOnly=false']
    commands = [
        ('privacy', [str(tree / 'scripts/personal-info-guard.sh')], tree),
        ('ownership', [sys.executable, 'tools/ownership/ownership.py'], tree),
        ('protocol', [sys.executable, 'scripts/verify-gateway-protocol-contract.py'], tree),
        ('docs', [sys.executable, 'scripts/check-documentation-policy.py'], tree),
        ('agent-policy', [str(tree / 'scripts/check-agent-policy.sh')], tree),
        ('comments', [sys.executable, 'tools/verify/comments.py', '--base', base], tree),
        ('determinism', [sys.executable, 'tools/verify/determinism.py', '--base', base], tree),
        ('gate-tests', [sys.executable, 'tools/verify/tests/test-gate.py'], tree),
        ('typecheck', [node, 'node_modules/typescript/bin/tsc', '-p', 'tsconfig.json', '--noEmit'], gateway),
        ('typecheck-tests', [node, 'node_modules/typescript/bin/tsc', '-p', 'tsconfig.test-support.json',
                             '--incremental', 'false'], gateway),
        ('lint', [node, 'node_modules/oxlint/bin/oxlint', '-c', '.oxlintrc.json', '--deny-warnings',
                  '--report-unused-disable-directives', 'src', 'test-support', 'test-fixtures', 'scripts'], gateway),
        ('gateway', [*vitest, '--maxWorkers=6', '--passWithNoTests=false', *GATEWAY_TESTS], gateway),
        *[(f'process-{Path(path).name.split(".")[0]}', [*vitest, '--config', 'vitest.nested.config.ts', path], gateway)
          for path in PROCESS_TESTS],
    ]
    for _, command, cwd in commands:
        missing = [part for part in command if part.startswith('src/') and not (cwd / part).is_file()]
        if missing:
            raise Refused(f'a gate test is missing: {missing[0]}')
    gate.parallel(commands, env)


def main(arguments: list[str], gate=checks, root: Path = ROOT) -> int:
    started = time.monotonic()
    if arguments[:1] == ['--pre-push'] and len(arguments) <= 2:
        remote = arguments[1] if len(arguments) == 2 else 'origin'
        updates = [line.split() for line in sys.stdin.read().splitlines() if line.strip()]
        main_updates = [update for update in updates if len(update) == 4 and update[2] == 'refs/heads/main']
        if not main_updates:
            return 0
        tip = main_updates[0][1]
        if len(main_updates) != 1 or set(tip) == {'0'}:
            print('gate: refused: one fast-forward update of main per push', file=sys.stderr)
            return 1
        if os.environ.get(TOKEN) == tip:
            return 0
        return Gate(root, started=started).admit(gate, tip=tip, push='pre-push', remote=remote)
    if arguments in ([], ['--check']):
        return Gate(root, started=started).admit(gate, push='check' if arguments else 'push')
    print('usage: scripts/tron gate [--check]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
