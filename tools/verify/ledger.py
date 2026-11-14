#!/usr/bin/env python3
"""Append execution-host test evidence and query same-tree nondeterminism."""
from __future__ import annotations

import argparse
import ctypes
from contextlib import closing
from datetime import datetime, timezone
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlsplit
import platform
import pwd
import re
import runpy
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
NODE_CASE = '@@tron-test-case '


def destination() -> Path:
    path = Path(os.environ.get('TRON_TEST_LEDGER', str(Path.home() / '.tron-maintenance/test-ledger/results.sqlite3'))).expanduser().resolve()
    protected = {(Path.home() / '.tron').resolve(), (Path(pwd.getpwuid(os.getuid()).pw_dir) / '.tron').resolve()}
    if any(path == root or root in path.parents for root in protected) or any((parent / '.git').exists() for parent in path.parents):
        raise ValueError('test ledger must be outside repositories and ~/.tron')
    return path


def database(write: bool = False):
    path = destination()
    if write:
        path.parent.mkdir(parents=True, exist_ok=True)
    elif not path.exists():
        return None
    connection = sqlite3.connect(str(path) if write else path.as_uri() + '?mode=ro', uri=not write, timeout=30)
    connection.row_factory = sqlite3.Row
    if write:
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('CREATE TABLE IF NOT EXISTS results (run_id TEXT NOT NULL, test_id TEXT NOT NULL, commit_sha TEXT NOT NULL, tree_hash TEXT NOT NULL, dirty INTEGER NOT NULL, outcome TEXT NOT NULL, seconds REAL NOT NULL, lane TEXT NOT NULL, host TEXT NOT NULL, cpu_idle_percent REAL, memory_free_percent REAL, measured_at TEXT NOT NULL, seen_at TEXT NOT NULL, contended INTEGER NOT NULL)')
    return connection


def append(records: list[dict]) -> None:
    if not records:
        return
    with closing(database(write=True)) as connection, connection:
        connection.executemany('INSERT INTO results VALUES (:runId, :testId, :commit, :tree, :dirty, :outcome, :seconds, :lane, :host, :cpuIdlePercent, :memoryFreePercent, :measuredAt, :seenAt, :contended)', records)


def append_rows(rows: list[list]) -> None:
    if rows:
        with closing(database(write=True)) as connection, connection:
            connection.executemany('INSERT INTO results VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', rows)


def reading() -> dict:
    cpu, memory = None, None
    if sys.platform == 'darwin':
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        samples = []
        for _ in range(2):
            ticks, count = (ctypes.c_uint32 * 4)(), ctypes.c_uint32(4)
            if library.host_statistics(library.mach_host_self(), 3, ticks, ctypes.byref(count)) == 0:
                samples.append(list(ticks))
            if len(samples) == 1:
                time.sleep(0.1)
        if len(samples) == 2:
            delta = [(end - start) % (2 ** 32) for start, end in zip(*samples)]
            cpu = round(100 * delta[2] / sum(delta), 2) if sum(delta) else None
        pages, count = (ctypes.c_uint32 * 15)(), ctypes.c_uint32(15)
        total, size = ctypes.c_uint64(), ctypes.c_size_t(8)
        if (library.host_statistics(library.mach_host_self(), 2, pages, ctypes.byref(count)) == 0
                and library.sysctlbyname(b'hw.memsize', ctypes.byref(total), ctypes.byref(size), None, 0) == 0 and total.value):
            memory = 100 * pages[0] * os.sysconf('SC_PAGE_SIZE') / total.value
    return {'host': platform.node(), 'cpuIdlePercent': cpu, 'memoryFreePercent': memory,
            'measuredAt': datetime.now(timezone.utc).isoformat()}


class Capture:
    def __init__(self, lane: str, root: Path = ROOT):
        destination()
        self.root = root.resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        revisions = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD', 'HEAD^{tree}'], text=True, env=environment).splitlines()
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=normal'], text=True, env=environment).strip())
        self.context = {'runId': uuid.uuid4().hex, 'commit': revisions[0], 'tree': revisions[1], 'dirty': int(dirty),
                        'lane': lane, 'contended': int(os.environ.get('TRON_TEST_CONTENDED') == '1'), **reading()}

    def record(self, identity: str, outcome: str, seconds: float, host_reading: dict | None = None) -> dict:
        return {**self.context, **(host_reading or {}), 'testId': identity, 'outcome': outcome, 'seconds': max(0, float(seconds)),
                'seenAt': datetime.now(timezone.utc).isoformat()}

    def events(self, report: Path) -> None:
        if not report.is_file():
            return
        records = []
        for line in report.read_text().split('\n'):
            if not line:
                continue
            case = json.loads(line)
            path = Path(case['file']).resolve()
            external = not path.is_relative_to(self.root)
            file = 'external/' + path.name if external else path.relative_to(self.root).as_posix()
            host_reading = {key: case[key] for key in ('host', 'cpuIdlePercent', 'memoryFreePercent', 'measuredAt')}
            record = self.record(file + '::' + case['fullName'], case['outcome'], case['seconds'], host_reading)
            if external:
                record['dirty'] = 1
            records.append(record)
        append(records)

    def vitest(self, report: Path) -> None:
        if not report.is_file():
            return
        data = json.loads(report.read_text())
        records = []
        for suite in data.get('testResults', []):
            path = Path(suite['name']).resolve()
            external = not path.is_relative_to(self.root)
            file = 'external/' + path.name if external else path.relative_to(self.root).as_posix()
            for case in suite.get('assertionResults', []):
                outcome = {'passed': 'passed', 'failed': 'failed', 'pending': 'skipped', 'todo': 'skipped', 'skipped': 'skipped'}.get(case['status'])
                if outcome:
                    record = self.record(file + '::' + case['fullName'], outcome, (case.get('duration') or 0) / 1000)
                    if external:
                        record['dirty'] = 1
                    records.append(record)
        append(records)

    def swift(self, output: str, bundles: list[Path]) -> None:
        paths = re.findall(r'(?:iOS test run (?:complete|failed with status \d+):|artifacts:|evidence:) (\S+)', output)
        for directory in paths:
            path = Path(directory) / 'test.log'
            if path.is_file():
                output += '\n' + path.read_text(errors='replace')
        bundles = list(dict.fromkeys([*bundles, *(bundle for directory in paths for bundle in Path(directory).glob('*.xcresult'))]))
        cases = {}
        for bundle in bundles:
            result = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle)], capture_output=True, text=True)
            if result.returncode == 0:
                cases.update(self.xctest_cases(json.loads(result.stdout)))
        if cases:
            append(list(cases.values()))
            return
        for target, klass, method, outcome, seconds in re.findall(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)", output):
            identity = f'{target}/{klass}/{method}'
            cases[identity] = self.record(identity, outcome, float(seconds))
        append(list(cases.values()))

    def xctest_cases(self, document: dict) -> dict:
        cases = {}
        pending = list(document.get('testNodes', []))
        while pending:
            node = pending.pop()
            pending.extend(node.get('children', []))
            if node.get('nodeType') != 'Test Case' or not node.get('nodeIdentifierURL'):
                continue
            path = unquote(urlsplit(node['nodeIdentifierURL']).path).strip('/').split('/')
            identity = '/'.join(path[1:])
            outcome = {'Passed': 'passed', 'Failed': 'failed', 'Skipped': 'skipped', 'Expected Failure': 'expected-failure'}.get(node.get('result'))
            if outcome:
                cases[identity] = self.record(identity, outcome, node.get('durationInSeconds') or 0)
        return cases


def python_main(arguments: list[str]) -> int:
    path = Path(arguments[0]).resolve()
    capture = Capture('python')
    external = not path.is_relative_to(ROOT)
    identity = 'external/' + path.name if external else path.relative_to(ROOT).as_posix()
    if external:
        capture.context['dirty'] = 1
    runner_used = False
    begun = time.monotonic()

    class Result(unittest.TextTestResult):
        def __init__(self, *args, **kwargs):
            nonlocal runner_used
            runner_used = True
            super().__init__(*args, **kwargs)

        def addError(self, test, error):
            super().addError(test, error)
            if not isinstance(test, unittest.TestCase):
                append([capture.record(identity + '::' + test.id().replace('__main__.', ''), 'failed', 0)])

        def addSkip(self, test, reason):
            super().addSkip(test, reason)
            if not isinstance(test, unittest.TestCase):
                append([capture.record(identity + '::' + test.id().replace('__main__.', ''), 'skipped', 0)])

        def startTest(self, test):
            self.begun = time.monotonic()
            self.before = len(self.failures) + len(self.errors)
            super().startTest(test)

        def stopTest(self, test):
            outcome = 'failed' if len(self.failures) + len(self.errors) > self.before else 'passed'
            if any(item is test for item, _ in self.skipped):
                outcome = 'skipped'
            elif any(item is test for item, _ in self.expectedFailures):
                outcome = 'expected-failure'
            elif test in self.unexpectedSuccesses:
                outcome = 'failed'
            append([capture.record(identity + '::' + test.id().removeprefix('__main__.'), outcome, time.monotonic() - self.begun)])
            super().stopTest(test)

    unittest.TextTestRunner.resultclass = Result
    sys.argv = arguments
    sys.path[0] = str(path.parent)
    code = 0
    try:
        runpy.run_path(str(path), run_name='__main__')
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else int(error.code is not None)
        raise
    except BaseException:
        code = 1
        raise
    finally:
        if not runner_used:
            append([capture.record(identity, 'failed' if code else 'passed', time.monotonic() - begun)])
    return code


def execute(kind: str, command: list[str], env: dict | None = None, cwd: Path | None = None) -> int:
    capture = Capture(kind)
    output, cases = [], []
    begun = time.monotonic()
    env = {**os.environ, **(env or {}), 'TRON_TEST_LEDGER_WRAPPED': '1',
           'TRON_TEST_LEDGER_CPU_IDLE': str(capture.context['cpuIdlePercent'])}
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd) as child:
        def forward(signum, _frame):
            if child.poll() is None:
                child.send_signal(signum)
        previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
        errors = []

        def pump(source, target):
            for line in source:
                try:
                    if line.startswith(NODE_CASE.encode()):
                        case = json.loads(line[len(NODE_CASE):])
                        file = Path(case['file']).resolve().relative_to(ROOT).as_posix()
                        host_reading = {key: case[key] for key in ('host', 'cpuIdlePercent', 'memoryFreePercent', 'measuredAt')}
                        cases.append(capture.record(file + '::' + case['name'], case['outcome'], case['seconds'], host_reading))
                    else:
                        target.buffer.write(line)
                        target.buffer.flush()
                        if kind == 'swift':
                            output.append(line)
                except Exception as error:
                    errors.append(error)

        threads = [threading.Thread(target=pump, args=(source, target)) for source, target in ((child.stdout, sys.stdout), (child.stderr, sys.stderr))]
        for thread in threads:
            thread.start()
        try:
            code = child.wait()
        finally:
            for thread in threads:
                thread.join()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
            append(cases)
            if kind == 'shell':
                append([capture.record(Path(command[-1]).resolve().relative_to(ROOT).as_posix(), 'passed' if child.returncode == 0 else 'failed', time.monotonic() - begun)])
            if kind == 'swift':
                capture.swift(b''.join(output).decode(errors='replace'), [Path(command[index + 1]) for index, word in enumerate(command[:-1]) if word == '-resultBundlePath'])
    if errors:
        raise errors[0]
    return code if code >= 0 else 128 - code


def flakes(tree: str | None = None) -> list[dict]:
    connection = database()
    if connection is None:
        return []
    with closing(connection):
        rows = connection.execute('SELECT test_id, tree_hash, SUM(outcome = \'passed\') AS passes, SUM(outcome = \'failed\') AS failures, MAX(seen_at) AS last_seen, GROUP_CONCAT(DISTINCT lane) AS lanes, GROUP_CONCAT(DISTINCT host) AS hosts FROM results WHERE dirty = 0 AND contended = 0 AND outcome IN (\'passed\', \'failed\') AND (? IS NULL OR tree_hash = ?) GROUP BY test_id, tree_hash HAVING passes > 0 AND failures > 0 ORDER BY CAST(failures AS REAL) / (passes + failures) DESC, failures DESC, last_seen DESC', (tree, tree)).fetchall()
        return [{**dict(row), 'failure_rate': row['failures'] / (row['passes'] + row['failures'])} for row in rows]


def main(arguments: list[str]) -> int:
    if arguments[:1] == ['python']:
        return python_main(arguments[1:])
    if arguments[:1] == ['exec']:
        return execute(arguments[1], arguments[2:])
    parser = argparse.ArgumentParser(prog='scripts/tron flakes')
    parser.add_argument('--tree')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(arguments)
    rows = flakes(args.tree)
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print(f'Test ledger: {destination()}')
        print('Same-tree flakes (uncontended committed runs only):')
        for row in rows:
            print(f"{row['failures']}/{row['passes'] + row['failures']} failed ({row['failure_rate']:.1%})  pass={row['passes']}  tree={row['tree_hash'][:12]}  last={row['last_seen']}  lanes={row['lanes']}  hosts={row['hosts']}  {row['test_id']}")
        if not rows:
            print('No test has both passed and failed on the same recorded tree.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
