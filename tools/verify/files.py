#!/usr/bin/env python3
"""Run one verify group's test files in parallel on this host's cores, printing each file's output whole when it ends (tools/verify/README.md)."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MARKER = '### verify file: '
STOPPING = threading.Event()
RUNNERS = {'python': ['python3', 'tools/verify/ledger.py', 'python'],
           'shell': ['python3', 'tools/verify/ledger.py', 'exec', 'shell', 'bash']}


def chains(files: list[str]) -> list[list[str]]:
    """Files that name another selected file load its fixture or share its output, so they run as one chain in selection
    order; chains start largest first, file size standing in for run time."""
    root = {path: path for path in files}

    def find(path: str) -> str:
        while root[path] != path:
            path = root[path]
        return path
    for path in files:
        text = (ROOT / path).read_text(errors='replace')
        for other in files:
            if other != path and Path(other).name in text:
                root[find(path)] = find(other)
    joined: dict[str, list[str]] = {}
    for path in files:
        joined.setdefault(find(path), []).append(path)
    return sorted(joined.values(), key=lambda chain: -sum((ROOT / path).stat().st_size for path in chain))


def main(arguments: list[str]) -> int:
    runner, files = RUNNERS[arguments[0]], arguments[1:]
    order = chains(files) if arguments[0] == 'python' else [files]
    codes: dict[str, int] = {}
    printing = threading.Lock()
    with tempfile.TemporaryDirectory(prefix='tron-verify-files-') as scratch:
        def run(chain: list[str]) -> None:
            for path in chain:
                if STOPPING.is_set():
                    return
                if len(order) == 1:
                    print(f'{MARKER}{path}', flush=True)
                    code = subprocess.run([*runner, path], cwd=ROOT, stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT).returncode
                else:
                    output = Path(scratch) / path.replace('/', '__')
                    with output.open('wb') as stream:
                        code = subprocess.run([*runner, path], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream,
                                              stderr=subprocess.STDOUT).returncode
                    with printing:
                        sys.stdout.buffer.write(f'{MARKER}{path}\n'.encode() + output.read_bytes())
                        sys.stdout.flush()
                codes[path] = code if code >= 0 else 128 - code
        with ThreadPoolExecutor(max(1, min(len(order), (os.cpu_count() or 2) // 2))) as pool:
            list(pool.map(run, order))
    return next((codes[path] for path in files if codes[path]), 0)


def stop(signum, _frame) -> None:
    STOPPING.set()
    sys.exit(128 + signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, stop)
    sys.exit(main(sys.argv[1:]))
