#!/usr/bin/env python3
"""Own the temporary HOME and scratch directory of one Gateway Vitest process."""
from __future__ import annotations
from pathlib import Path
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_lock import HELD_BY_CALLER, wait_for_full_gateway_lock  # noqa: E402  (the one host lock owner)
import vitest_configs  # noqa: E402  (the one reader of the listing Vitest configs)
import ledger


def hold_full_gateway_lock():
    """The open, exclusively locked lock file, after waiting its turn behind any holder and earlier waiters; None when the caller holds it."""
    if os.environ.get(HELD_BY_CALLER) == '1':
        return None
    record = {'pid': os.getpid(), 'worktree': str(ROOT), 'purpose': 'gateway vitest ' + ' '.join(sys.argv[1:])[:200]}
    return wait_for_full_gateway_lock(record, lambda line: print(f'gateway tests: {line}', file=sys.stderr, flush=True))


VALUE_OPTIONS = {'--config', '-c', '--project', '--reporter', '--outputFile', '-t', '--testNamePattern', '--root', '-r', '--dir', '--shard',
                 '--testTimeout', '--hookTimeout', '--teardownTimeout', '--bail', '--retry', '--maxWorkers', '--minWorkers', '--pool',
                 '--environment', '--maxConcurrency', '--sequence.seed', '--exclude'}


def vitest_selection(args: list[str]) -> tuple[str | None, list[tuple[str, str]]]:
    """The config file this Vitest selection names, if any, and each file filter as given and relative to the Gateway package."""
    config, filters, value = None, [], None
    for word in args:
        if value:
            if value in ('--config', '-c'):
                config = word
            value = None
        elif word.split('=', 1)[0] in ('--config', '-c') and '=' in word:
            config = word.split('=', 1)[1]
        elif word in VALUE_OPTIONS:
            value = word
        elif not word.startswith('-'):
            relative = re.sub(r':\d+$', '', word).removeprefix(str(ROOT / 'packages/gateway') + '/')
            filters.append((word, relative.removeprefix('./').removeprefix('packages/gateway/')))
    return config, filters


def filter_selects(relative: str, path: str) -> bool:
    """Whether a file filter selects the test file at `path`: Vitest's rule, the path contains the filter ignoring case."""
    return relative.lower() in path.lower()


def with_own_config(args: list[str]) -> list[str]:
    """`args` under the one config that runs every file its filters select: a listing config when that is it.

    A filter selects each test file `filter_selects` matches. Filters selecting files of
    more than one config are refused with each config's command, since any one config would skip the rest."""
    config, filters = vitest_selection(args)
    if config is not None or not filters:
        return args
    gateway = ROOT / 'packages/gateway'
    listed = vitest_configs.listed_files(gateway)
    owners = {path.relative_to(gateway).as_posix(): None for path in (gateway / 'src').rglob('*.test.ts')}
    owners.update({path: name for name, paths in listed.items() for path in paths})
    selected: dict[str | None, list[str]] = {}
    for word, relative in filters:
        for name in {owner for path, owner in owners.items() if filter_selects(relative, path)} or {None}:
            selected.setdefault(name, []).append(word)
    if len(selected) == 1:
        name = next(iter(selected))
        return args if name is None else ['--config', name, *args]
    options = ' '.join(word for word in args if word not in {raw for raw, _ in filters})
    commands = [' '.join(['scripts/tron test gateway', '--config', name or 'vitest.config.ts', *([options] if options else []), *words])
                for name, words in sorted(selected.items(), key=lambda item: item[0] or '')]
    raise Refused('gateway tests: these files run under different Vitest configs; run each set under its own:\n  '
                  + '\n  '.join(commands))


class Refused(Exception):
    """A selection this runner cannot run as one Vitest process; nothing ran."""


def browser_fixture_environment(arguments: list[str], node: str) -> dict[str, str]:
    files = ('src/e2e/sessions/browser-fork-receipts.integration.test.ts', 'src/e2e/automations/home-tool-admission.e2e.test.ts')
    _, filters = vitest_selection(arguments)
    if filters and not any(filter_selects(relative, path) for _, relative in filters for path in files):
        return {}
    if not any((ROOT / 'packages/gateway' / path).is_file() for path in files):
        return {}
    script = "import {chromeForTesting} from './tools/computer-bench/process.mjs'; console.log(chromeForTesting()?.binary ?? '')"
    binary = subprocess.check_output([node, '--input-type=module', '-e', script], cwd=ROOT, text=True).strip()
    if not binary:
        raise SystemExit('Gateway browser fixtures require cached Chrome for Testing; no personal browser fallback')
    return {'AGENT_BROWSER_EXECUTABLE_PATH': binary, 'AGENT_BROWSER_ARGS': '--password-store=basic,--use-mock-keychain'}


def main() -> int:
    node = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
    vitest = ROOT / "packages/gateway/node_modules/.bin/vitest"
    if not vitest.is_file():
        raise SystemExit("Gateway Vitest is missing; prepare this worktree's pinned dependencies first")
    try:
        arguments = with_own_config(sys.argv[1:])
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
