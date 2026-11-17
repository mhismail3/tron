#!/usr/bin/env python3
"""Refuse new real-time, fixed-port, skip/only and retry sites in Gateway test code against a shrink-only baseline (tools/verify/README.md)."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = "packages/gateway"
BASELINE = f"{GATEWAY}/determinism-baseline.json"
RULES = {
    "sleep": re.compile(r"setTimeout\(\s*(resolve|res|r|done|wake)\s*,|\bawait\s+(sleep|delay|setTimeout)\(\s*[0-9]"),
    "wall-clock-expect": re.compile(r"expect\([^\n]*(Date\.now|performance\.now)\(\)"),
    "timeout-literal": re.compile(r"\},\s*[0-9][0-9_]*\s*\)|\btimeout:\s*[0-9][0-9_]*"),
    "fixed-port": re.compile(r"\.listen\(\s*[1-9][0-9]*\b"),
    "skip-only": re.compile(r"\b(it|test|describe|suite)(\.each\([^)]*\))?\.(skip|only)\b"),
    "retry": re.compile(r"\bretry:\s*[0-9]"),
}


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=check)


def scanned() -> list[str]:
    files = git("ls-files", "--cached", "--others", "--exclude-standard", "--", f"{GATEWAY}/src", f"{GATEWAY}/test-support", f"{GATEWAY}/test-fixtures").stdout.split()
    return sorted(path for path in files if path.endswith(".ts")
                  and (path.endswith(".test.ts") or path.startswith((f"{GATEWAY}/test-support/", f"{GATEWAY}/test-fixtures/"))))


def measure() -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {}
    for path in scanned():
        text = (ROOT / path).read_text()
        counts = Counter({rule: len(pattern.findall(text)) for rule, pattern in RULES.items()})
        counts = {rule: count for rule, count in counts.items() if count}
        if counts:
            found[path[len(GATEWAY) + 1:]] = dict(sorted(counts.items()))
    return found


def load(text: str | None, origin: str) -> dict[str, dict[str, int]] | None:
    if text is None:
        return None
    try:
        sites = json.loads(text)["sites"]
        if not all(isinstance(rules, dict) and all(rule in RULES and isinstance(n, int) and n > 0 for rule, n in rules.items())
                   for rules in sites.values()):
            raise ValueError("sites must map files to positive counts of known rules")
        return sites
    except (ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"determinism: {origin}: malformed baseline ({error})")


def write(sites: dict[str, dict[str, int]]) -> None:
    data = {"comment": "Shrink-only: scripts/tron determinism --update removes fixed sites; new sites are never added "
                       "(tools/verify/README.md).", "sites": sites}
    (ROOT / BASELINE).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def compare(current: dict, allowed: dict) -> tuple[list[str], list[str]]:
    grew, fixed = [], []
    for path in sorted(set(current) | set(allowed)):
        for rule in RULES:
            now, then = current.get(path, {}).get(rule, 0), allowed.get(path, {}).get(rule, 0)
            if now > then:
                grew.append(f"{rule}: {GATEWAY}/{path} [{then} -> {now}]")
            elif now < then:
                fixed.append(f"{rule}: {GATEWAY}/{path} [{then} -> {now}]")
    return grew, fixed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--update", action="store_true", help="remove fixed sites from the baseline")
    args = parser.parse_args(argv)
    shown = git("show", f"{args.base}:{BASELINE}", check=False)
    bound = load(shown.stdout if shown.returncode == 0 else None, f"{args.base}:{BASELINE}")
    path = ROOT / BASELINE
    baseline = load(path.read_text() if path.exists() else None, BASELINE)
    current = measure()
    problems = []
    if bound is not None:
        if baseline is None:
            raise SystemExit(f"determinism: {BASELINE} is missing but {args.base} has one; restore it")
        problems += [f"baseline grew past {args.base}: {line}" for line in compare(baseline, bound)[0]]
    if args.update:
        if baseline is not None and compare(current, baseline)[0]:
            problems.append("--update only removes fixed sites; new sites cannot be baselined")
        else:
            write({file: {rule: min(n, (baseline or current).get(file, {}).get(rule, 0)) for rule, n in rules.items()}
                   for file, rules in current.items()})
            print(f"determinism: baseline {'written' if baseline is None else 'tightened'}: {len(current)} files")
            baseline = current
    grew, fixed = compare(current, baseline or {})
    problems += [f"new site (tools/verify/README.md determinism): {line}" for line in grew]
    problems += [f"improved, tighten the baseline (scripts/tron determinism --update): {line}" for line in fixed]
    for line in problems:
        print(f"determinism: {line}")
    totals = Counter()
    for rules in current.values():
        totals.update(rules)
    print("determinism: " + ", ".join(f"{rule} {totals[rule]}" for rule in RULES) + f" across {len(current)} files")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
