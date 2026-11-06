#!/usr/bin/env python3
"""Doc budgets: reported above budget, failing only far over it (tools/budgets/README.md)."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "metrics"))
import metrics  # noqa: E402  (the one classification and line-count authority)

# A doc fails only above this multiple of its budget; between budget and limit it is reported.
DOC_FACTOR = 2
# The front door and the agent charter (AGENTS.md "Documentation") fail at their budget itself.
HARD_LIMITS = {"README.md": 250, "AGENTS.md": 150}


def doc_budget(path: str) -> int:
    parts = path.split("/")
    if parts[-1] == "README.md":
        return 200 if len(parts) == 3 and parts[0] == "packages" else 150
    return 300


def main(argv: list[str]) -> int:
    if len(argv) > 1 or any(a.startswith("-") for a in argv):
        print("usage: scripts/tron budgets [<rev>]", file=sys.stderr)
        return 2
    revision = argv[0] if argv else "HEAD"
    try:
        sha = metrics.resolve(revision)
        files = metrics.read_tree(sha)
    except metrics.MetricsError as error:
        print(f"budgets: {error}", file=sys.stderr)
        return 2
    problems, over = [], 0
    for f in sorted(files, key=lambda f: f["path"]):
        path, lines = f["path"], f["lines"]
        if f["category"] != "docs":
            continue
        if path in HARD_LIMITS:
            if lines > HARD_LIMITS[path]:
                problems.append(f"{path} has {lines} lines; maximum is {HARD_LIMITS[path]}")
            continue
        budget = doc_budget(path)
        over += lines > budget
        if lines > DOC_FACTOR * budget:
            problems.append(f"doc over {DOC_FACTOR}x budget: {path} has {lines} lines; budget is {budget}, "
                            f"limit {DOC_FACTOR * budget} (split it by owner)")
    for line in problems:
        print(line)
    print(f"budgets: {revision} ({sha[:12]}): {over} docs over budget (reported); "
          + (f"{len(problems)} problem(s)" if problems else f"no doc over {DOC_FACTOR}x budget"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
