"""Runs the work-tooling unit tests: one `python3 -m unittest <module>` process per module, bounded.

This is the `work-tooling` verify check and CI's "Test the work tooling" step. Modules
share no state (each owns its temporary repositories, fake `gh` and environment), so
they run side by side and the suite takes about as long as its slowest module. Each
module runs from the caller's directory with this directory on PYTHONPATH, as
`unittest discover -s tools/work` runs them. The default bound is min(4, CPUs);
WORK_TEST_JOBS overrides it.
"""
from __future__ import annotations

import contextlib
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

TOOLS = Path(__file__).resolve().parent
JOBS_VARIABLE = "WORK_TEST_JOBS"
# discover's default pattern, so the runner selects the modules discover would load.
MODULE_PATTERN = "test*.py"
_RAN = re.compile(r"^Ran (\d+) tests?", re.MULTILINE)
_INTERRUPTS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
_SETTLE_SECONDS = 10


@dataclass
class _Running:
    name: str
    process: subprocess.Popen
    log: Path
    started: float


@dataclass
class _Outcome:
    name: str
    exit_code: int
    seconds: float
    output: str


def job_count() -> int:
    raw = os.environ.get(JOBS_VARIABLE)
    if raw is None:
        return max(1, min(4, os.cpu_count() or 1))
    if not raw.isdigit() or int(raw) < 1:
        raise SystemExit(f"{JOBS_VARIABLE} must be a positive integer, not {raw!r}")
    return int(raw)


def module_names() -> List[str]:
    return sorted(path.stem for path in TOOLS.glob(MODULE_PATTERN) if path.is_file())


def _retire(process: subprocess.Popen) -> None:
    """Ends the module's process group, including descendants it left running."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=_SETTLE_SECONDS)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)


def run_modules(names: List[str], jobs: int, log_dir: Path) -> Dict[str, _Outcome]:
    environment = {**os.environ,
                   "PYTHONPATH": os.pathsep.join(filter(None, (str(TOOLS), os.environ.get("PYTHONPATH"))))}
    pending = list(names)
    running: List[_Running] = []
    outcomes: Dict[str, _Outcome] = {}
    handlers = [(number, signal.getsignal(number)) for number in _INTERRUPTS]

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for number in _INTERRUPTS:
        signal.signal(number, interrupted)
    try:
        while pending or running:
            while pending and len(running) < jobs:
                name = pending.pop(0)
                log = log_dir / f"{name}.log"
                # The child inherits the descriptor, so the parent does not keep the log open.
                with log.open("w") as handle:
                    process = subprocess.Popen(
                        [sys.executable, "-m", "unittest", name], env=environment,
                        stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                print(f"{name}: running", flush=True)
                running.append(_Running(name, process, log, time.monotonic()))
            for item in running[:]:
                code = item.process.poll()
                if code is None:
                    continue
                _retire(item.process)
                running.remove(item)
                outcomes[item.name] = _Outcome(item.name, code, round(time.monotonic() - item.started, 1),
                                               item.log.read_text(errors="replace"))
            if running:
                time.sleep(0.05)
    finally:
        for item in running:
            _retire(item.process)
        for number, handler in handlers:
            signal.signal(number, handler)
    return outcomes


def main() -> int:
    names = module_names()
    if not names:
        raise SystemExit(f"no test modules match {MODULE_PATTERN} in {TOOLS}")
    jobs = job_count()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="work-tests-") as log_dir:
        outcomes = run_modules(names, jobs, Path(log_dir))
    wall = round(time.monotonic() - started, 1)

    failed: List[_Outcome] = []
    total = 0
    counted = 0
    for name in names:
        outcome = outcomes[name]
        match = _RAN.search(outcome.output)
        if match:
            total += int(match.group(1))
            counted += 1
        tests = f"{match.group(1)} test{'' if match.group(1) == '1' else 's'}" if match else "no test count"
        status = "passed" if outcome.exit_code == 0 else f"FAILED (exit {outcome.exit_code})"
        print(f"{name}: {status}, {tests}, {outcome.seconds}s")
        if outcome.exit_code != 0:
            failed.append(outcome)
    print(f"work tests: {total} tests in {len(names)} modules ({counted} reported a count), "
          f"{len(failed)} failed, {wall}s wall with {jobs} jobs")
    for outcome in failed:
        print(f"\n===== {outcome.name}: full output =====")
        print(outcome.output.rstrip())
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
