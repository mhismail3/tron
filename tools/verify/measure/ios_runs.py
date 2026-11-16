#!/usr/bin/env python3
"""Read-only audit of retained iOS runner directories: build, launch overhead, test seconds, outcomes and idle stalls."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

CASE = re.compile(rb"^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed) \((\d+(?:\.\d+)?) seconds\)", re.M)
STALL = re.compile(rb"App animations complete notification not received")
IDLE = re.compile(rb"Wait for \S+ to idle")
NAME = re.compile(r"^(\d{8}T\d{6}Z)-(\w+)\.")


def quantile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(q * (len(ordered) - 1)))] if ordered else float("nan")


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def row(label: str, values: list[float]) -> str:
    return (f"  {label:34s} n={len(values):5d} p50={quantile(values, 0.5):8.1f} p95={quantile(values, 0.95):8.1f} "
            f"max={max(values, default=float('nan')):8.1f} hours={sum(values) / 3600:7.1f}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Developer/Tron/ios/test-runs")
    parser.add_argument("--since", default="2026-10-26")
    parser.add_argument("--tests", type=Path, help="write per-test statistics as TSV here")
    args = parser.parse_args()
    since = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)

    commands = Counter()
    outcome: dict[str, Counter] = defaultdict(Counter)
    elapsed: dict[str, list[float]] = defaultdict(list)
    overhead, tested, share, cases_per_run = [], [], [], []
    tests: dict[str, list[tuple[str, float, str]]] = defaultdict(list)
    stalled_runs = idle_waits = runs_with_log = 0
    by_revision: dict[tuple[str, str], Counter] = defaultdict(Counter)
    for directory in sorted(args.root.iterdir()):
        found = NAME.match(directory.name)
        if not found or datetime.strptime(found.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc) < since:
            continue
        metadata = load(directory / "metadata.json") or {}
        process = load(directory / "test-evidence/process.json") or load(directory / "build-evidence/process.json") or {}
        command = metadata.get("command") or found.group(2)
        commands[command] += 1
        code = metadata.get("exit_code")
        outcome[command]["ok" if code == 0 else "no exit" if code is None else f"exit {code}"] += 1
        seconds = process.get("elapsed_seconds")
        if isinstance(seconds, (int, float)):
            elapsed[command].append(float(seconds))
        log = directory / "test.log"
        if command != "run" or not log.is_file():
            continue
        text = log.read_bytes()
        runs_with_log += 1
        cases = CASE.findall(text)
        if STALL.search(text):
            stalled_runs += 1
        idle_waits += len(IDLE.findall(text))
        revision = ((metadata.get("source") or {}).get("revision") or "?") + ("+dirty" if (metadata.get("source") or {}).get("dirty") else "")
        total = 0.0
        for _, suite, method, result, took in cases:
            identity = f"{suite.decode()}/{method.decode()}"
            tests[identity].append((result.decode(), float(took), revision))
            by_revision[(identity, revision)][result.decode()] += 1
            total += float(took)
        if cases and isinstance(seconds, (int, float)) and seconds > 0:
            tested.append(total)
            overhead.append(max(0.0, seconds - total))
            share.append(max(0.0, seconds - total) / seconds)
            cases_per_run.append(len(cases))

    print(f"runner directories since {args.since}: {sum(commands.values())}  by command: {dict(commands)}")
    for command, counts in outcome.items():
        print(f"  {command}: {dict(counts)}")
    print("\nprocess seconds by command")
    for command, values in elapsed.items():
        print(row(command, values))
    print("\ntest runs with cases (xcodebuild test-without-building)")
    print(row("test cases, summed per run", tested))
    print(row("launch and teardown overhead per run", overhead))
    print(f"  overhead share of a run: p50={quantile(share, 0.5):.0%} p95={quantile(share, 0.95):.0%}; "
          f"total overhead {sum(overhead) / 3600:.1f} h of {(sum(overhead) + sum(tested)) / 3600:.1f} h")
    print(f"  cases per run: p50={quantile(cases_per_run, 0.5):.0f} p95={quantile(cases_per_run, 0.95):.0f}")
    every = [took for records in tests.values() for _, took, _ in records]
    print(row("one test case", every))
    print(f"\nruns whose log has 'App animations complete notification not received': {stalled_runs} of {runs_with_log}")
    print(f"'Wait for <app> to idle' lines: {idle_waits}")
    reversed_tests = Counter()
    for (identity, revision), counts in by_revision.items():
        if counts["passed"] and counts["failed"] and not revision.endswith("+dirty"):
            reversed_tests[identity] += 1
    print(f"\ntests that both passed and failed on one clean revision: {len(reversed_tests)} of {len(tests)}")
    for identity, count in reversed_tests.most_common(25):
        records = tests[identity]
        failed = sum(1 for result, _, _ in records if result == "failed")
        print(f"  {identity}: {count} revision(s); {failed} failed of {len(records)} executions")
    if args.tests:
        lines = ["test\texecutions\tfailed\tp50\tp95\tmax\treversed_revisions\n"]
        for identity, records in sorted(tests.items(), key=lambda item: -quantile([took for _, took, _ in item[1]], 0.5)):
            took = [seconds for _, seconds, _ in records]
            lines.append(f"{identity}\t{len(records)}\t{sum(1 for result, _, _ in records if result == 'failed')}\t"
                         f"{quantile(took, 0.5):.1f}\t{quantile(took, 0.95):.1f}\t{max(took):.1f}\t{reversed_tests.get(identity, 0)}\n")
        args.tests.write_text("".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
