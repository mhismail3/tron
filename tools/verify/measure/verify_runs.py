#!/usr/bin/env python3
"""Read-only audit of past `scripts/tron verify` reports: step time split, verdicts and same-commit reversals."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

SETUP = ("ios build",)
STATIC = ("ownership", "worktree residue", "documentation policy", "generated docs", "agent policy", "home layout",
          "privacy guard", "git diff --check", "no new comments", "context audit", "gateway typecheck", "gateway lint",
          "layers gateway", "layers ios", "ios source policy")


def bucket(name: str) -> str:
    if name in SETUP:
        return "setup"
    if name in STATIC:
        return "static"
    if name.startswith("tests:"):
        return "tests"
    return "other"


def lane(name: str) -> str:
    return re.sub(r" \d+/\d+$", "", name)


def quantile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    return ordered[min(len(ordered) - 1, round(q * (len(ordered) - 1)))]


def seconds_between(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    return (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds()


def reports(roots: list[Path]):
    seen = set()
    for root in roots:
        for path in list(root.glob("test-results/verify/*.json")) + list(root.glob("test-results/mini/*/verify.json")) \
                + list(root.glob("*/test-results/verify/*.json")) + list(root.glob("*/test-results/mini/*/verify.json")):
            try:
                data = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if data.get("schema") != "tron.verify.v1":
                continue
            key = (data.get("commit"), data.get("attemptId"))
            if key in seen:
                continue
            seen.add(key)
            yield path, data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roots", nargs="+", type=Path, help="checkouts or a directory of worktrees")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    runs = []
    step_seconds: dict[str, list[float]] = defaultdict(list)
    step_status: dict[str, Counter] = defaultdict(Counter)
    by_commit: dict[tuple, list] = defaultdict(list)
    for path, data in reports(args.roots):
        steps = data.get("steps") or []
        wall = seconds_between(data.get("startedAt"), data.get("endedAt"))
        split = Counter()
        for step in steps:
            seconds = step.get("seconds") or 0.0
            split[bucket(step["name"])] += seconds
            if step.get("status") in ("ok", "failed"):
                step_seconds[lane(step["name"])].append(seconds)
            step_status[lane(step["name"])][step.get("status")] += 1
        stepped = sum(split.values())
        run = {"path": str(path), "commit": data.get("commit"), "verdict": data.get("verdict"),
               "mode": (data.get("selection") or {}).get("mode"), "tier": (data.get("selection") or {}).get("tier"),
               "host": (data.get("environment") or {}).get("gatewayHost"), "wall": wall,
               "static": split["static"], "setup": split["setup"], "tests": split["tests"],
               "unaccounted": (wall - stepped) if wall is not None else None,
               "failed": [step["name"] for step in steps if step.get("status") == "failed"],
               "noResult": [step["name"] for step in steps if step.get("status") == "no result"],
               "message": data.get("message"), "startedAt": data.get("startedAt")}
        runs.append(run)
        by_commit[(run["commit"], json.dumps(data.get("selection", {}).get("tests"), sort_keys=True))].append(run)

    finished = [run for run in runs if run["verdict"] in ("passed", "failed", "incomplete") and run["wall"]]
    summary = {"reports": len(runs), "verdicts": Counter(run["verdict"] for run in runs),
               "byMode": {mode: Counter(run["verdict"] for run in runs if run["mode"] == mode)
                          for mode in sorted({run["mode"] or "?" for run in runs})},
               "firstStarted": min((run["startedAt"] for run in runs if run["startedAt"]), default=None),
               "lastStarted": max((run["startedAt"] for run in runs if run["startedAt"]), default=None)}
    wall = {}
    for label in ("wall", "static", "setup", "tests", "unaccounted"):
        values = [run[label] for run in finished if run[label] is not None]
        wall[label] = {"n": len(values), "p50": quantile(values, 0.5), "p95": quantile(values, 0.95),
                       "max": max(values, default=float("nan")), "sum": sum(values)}
    with_ios = [run for run in finished if run["setup"] > 0]
    steps = {name: {"n": len(values), "p50": quantile(values, 0.5), "p95": quantile(values, 0.95), "max": max(values),
                    "sum": sum(values), "status": dict(step_status[name])}
             for name, values in step_seconds.items()}
    failing = Counter(name for run in runs for name in run["failed"])
    reversals = []
    for (commit, _), group in by_commit.items():
        verdicts = {run["verdict"] for run in group}
        if "passed" in verdicts and "failed" in verdicts:
            reversals.append({"commit": commit, "runs": [(run["verdict"], run["failed"], run["path"]) for run in group]})
    result = {"summary": summary, "wall": wall, "iosBuildRuns": len(with_ios), "steps": steps,
              "failingSteps": failing.most_common(), "sameCommitReversals": reversals,
              "failedMessages": Counter(re.sub(r"[0-9a-f]{12,}", "<sha>", run["message"] or "")[:160]
                                        for run in runs if run["verdict"] == "failed").most_common(40)}
    if args.json:
        json.dump(result, sys.stdout, indent=2, default=dict)
        return 0
    print(f"reports: {summary['reports']}  {summary['firstStarted']} .. {summary['lastStarted']}")
    print(f"verdicts: {dict(summary['verdicts'])}")
    for mode, counts in summary["byMode"].items():
        print(f"  mode {mode}: {dict(counts)}")
    print("\nper-run seconds (finished runs)")
    for label, row in wall.items():
        print(f"  {label:12s} n={row['n']:3d} p50={row['p50']:8.1f} p95={row['p95']:8.1f} max={row['max']:8.1f} sum={row['sum']:9.0f}")
    print("\nper-step seconds (ok or failed)")
    for name, row in sorted(steps.items(), key=lambda item: -item[1]["sum"]):
        print(f"  {name:28s} n={row['n']:3d} p50={row['p50']:7.1f} p95={row['p95']:7.1f} max={row['max']:7.1f} sum={row['sum']:8.0f} {row['status']}")
    print("\nfailing steps:", failing.most_common())
    print(f"\nsame-commit, same-selection reversals (passed and failed): {len(reversals)}")
    for item in reversals:
        print(f"  {item['commit'][:12]}: {[(verdict, failed) for verdict, failed, _ in item['runs']]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
