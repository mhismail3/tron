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
    return [path for path in files if path.endswith(".ts") and (ROOT / path).is_file()
            and (path.endswith(".test.ts") or path.startswith((f"{GATEWAY}/test-support/", f"{GATEWAY}/test-fixtures/")))]


def measure() -> dict[str, dict[str, int]]:
    found: dict[str, dict[str, int]] = {}
    for path in scanned():
        text = (ROOT / path).read_text()
        counts = {rule: n for rule, pattern in RULES.items() if (n := len(pattern.findall(text)))}
        if counts:
            found[path[len(GATEWAY) + 1:]] = counts
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


def grown(sites: dict, bound: dict) -> list[str]:
    lines, moved, freed = [], Counter(), Counter()
    for path, rules in sites.items():
        if path in bound:
            lines += [f"{rule}: {GATEWAY}/{path} [{bound[path].get(rule, 0)} -> {n}]"
                      for rule, n in rules.items() if n > bound[path].get(rule, 0)]
        else:
            moved.update(rules)
    for path, rules in bound.items():
        if path not in sites and not (ROOT / GATEWAY / path).exists():
            freed.update(rules)
    return lines + [f"{rule}: new files [{freed[rule]} freed by deleted files -> {moved[rule]}]"
                    for rule in RULES if moved[rule] > freed[rule]]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--update", action="store_true", help="remove fixed sites from the baseline")
    args = parser.parse_args(argv)
    if git("rev-parse", "--verify", "--quiet", f"{args.base}^{{commit}}", check=False).returncode:
        raise SystemExit(f"determinism: base {args.base} not found; pass --base <ref>")
    shown = git("show", f"{args.base}:{BASELINE}", check=False)
    bound = load(shown.stdout if shown.returncode == 0 else None, f"{args.base}:{BASELINE}")
    path = ROOT / BASELINE
    baseline = load(path.read_text() if path.exists() else None, BASELINE)
    current = measure()
    problems = []
    if bound is not None:
        if baseline is None:
            raise SystemExit(f"determinism: {BASELINE} is missing but {args.base} has one; restore it")
        problems += [f"baseline grew past {args.base}: {line}" for line in grown(baseline, bound)]
    if args.update:
        if baseline is not None and grown(current, baseline):
            problems.append("--update only removes fixed sites; new sites cannot be baselined")
        else:
            write(current)
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
