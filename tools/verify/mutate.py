#!/usr/bin/env python3
"""scripts/tron mutate: seeded, sampled mutation of one source file against the locks verify selects.

Milestone lock sensitivity (plan §3 M1, §6.6; maintainer decision 2026-10-19 on #1345, from
the #1465 evaluation): each sampled mutant flips one operator in the file, the *locks*
`scripts/tron verify` would select for a change to that file run, and a failing run kills
the mutant. M1 measures what locks catch, so module journeys are not part of the run. It measures and never gates: the exit status is non-zero only for usage errors.
The source file is restored after every mutant, including on interrupt.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify  # noqa: E402  (selection and runners)

OPERATORS = [(r"===", "!=="), (r"!==", "==="), (r" && ", " || "), (r" \|\| ", " && "), (r"\btrue\b", "false"),
             (r"\bfalse\b", "true"), (r" < ", " >= "), (r" > ", " <= "), (r" <= ", " > "), (r" >= ", " < "),
             (r" \+ 1\b", " - 1"), (r" - 1\b", " + 1")]


def candidates(lines: list[str]) -> list[tuple[int, int, int, str]]:
    found = []
    for index, line in enumerate(lines):
        if line.strip().startswith(("//", "*", "/*", "import ")):
            continue
        for pattern, replacement in OPERATORS:
            found += [(index, match.start(), match.end(), replacement) for match in re.finditer(pattern, line)]
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron mutate")
    parser.add_argument("file", help="repository-relative Gateway source file")
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--seed", type=int, default=1465)
    args = parser.parse_args(argv)
    path = verify.ROOT / args.file
    if not path.is_file() or not args.file.startswith(f"{verify.GATEWAY}/src/") or args.file.endswith(".test.ts"):
        parser.error("mutate takes one Gateway source file under packages/gateway/src")
    if verify.git("status", "--porcelain", "--untracked-files=normal").strip():
        parser.error("the worktree has uncommitted changes; mutate restores the file and needs a clean start")
    result, _ = verify.ownership.check()
    selection = verify.select("changed", None, "HEAD", result["modules"], result["tracked"], paths=[args.file])
    nested, mac_terminal = verify.nested_files()
    tests = [test for test in selection["tests"]
             if verify.is_lock(test) and verify.runner_of(test, nested, mac_terminal) == "gateway"]
    if not tests:
        parser.error(f"no Gateway vitest lock is selected for {args.file}")
    command = [str(verify.ROOT / "scripts" / "tron-node"), "exec", "npx", "vitest", "run",
               *[test[len(verify.GATEWAY) + 1:] for test in tests]]
    source = path.read_text()
    lines = source.split("\n")
    pool = candidates(lines)
    random.Random(args.seed).shuffle(pool)
    sample = pool[:args.count]
    print(f"mutate {args.file}: {len(sample)} of {len(pool)} candidate mutants (seed {args.seed}) against "
          f"{len(tests)} selected lock file(s)", flush=True)
    for reason in selection["reasons"]:
        print(f"  why: {reason}", flush=True)
    mutants, started = [], time.time()
    try:
        for number, (index, start, end, replacement) in enumerate(sample, 1):
            mutated = lines[:]
            mutated[index] = lines[index][:start] + replacement + lines[index][end:]
            path.write_text("\n".join(mutated))
            begun = time.time()
            killed = subprocess.run(command, cwd=verify.ROOT / verify.GATEWAY, capture_output=True).returncode != 0
            path.write_text(source)
            mutants.append({"line": index + 1, "from": lines[index][start:end].strip(), "to": replacement.strip(),
                            "killed": killed, "seconds": round(time.time() - begun, 1)})
            print(f"[{number}/{len(sample)}] line {index + 1}: {mutants[-1]['from']} → {mutants[-1]['to']} "
                  f"{'killed' if killed else 'SURVIVED'}", flush=True)
    finally:
        path.write_text(source)
    killed = sum(mutant["killed"] for mutant in mutants)
    report = {"schema": "tron.mutate.v1", "file": args.file, "commit": verify.git("rev-parse", "HEAD").strip(),
              "seed": args.seed, "candidates": len(pool), "sampled": len(mutants), "killed": killed,
              "rate": round(killed / len(mutants), 3) if mutants else None, "tests": tests,
              "seconds": round(time.time() - started), "mutants": mutants}
    out = verify.ROOT / "test-results" / "mutate" / f"{args.file.replace('/', '__')}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"mutate: {killed}/{len(mutants)} killed ({report['rate']}) in {report['seconds']}s; report {out.relative_to(verify.ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
