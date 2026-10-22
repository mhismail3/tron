#!/usr/bin/env python3
"""File-size and doc budgets: reported, failing only on a new oversized production file or a doc
far over its budget (tools/budgets/README.md)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "metrics"))
import metrics  # noqa: E402  (the one classification and line-count authority)

LINE_BUDGET = metrics.SIZE_THRESHOLD
# A change may not create a production file above this; existing files only report against LINE_BUDGET.
NEW_FILE_LIMIT = 800
# A doc fails only above this multiple of its budget; between budget and limit it is reported.
DOC_FACTOR = 2
# The charter's two root budgets are owned by scripts/check-documentation-policy.py.
POLICY_OWNED = {"README.md", "AGENTS.md"}
# Plan §0: the restructure plan is exempt from doc budgets until epic exit (M6), when it is deleted.
EXEMPT = {"docs/restructure/plan.md"}


class BudgetError(Exception):
    pass


def doc_budget(path: str) -> int:
    parts = path.split("/")
    if parts[-1] == "README.md":
        return 200 if len(parts) == 3 and parts[0] == "packages" else 150
    return 300


def measure(revision: str) -> dict:
    try:
        sha = metrics.resolve(revision)
        return {"sha": sha, "files": {f["path"]: f for f in metrics.read_tree(sha)}}
    except metrics.MetricsError as error:
        raise BudgetError(str(error)) from error


def moves(base: str, head: str) -> tuple[set, set]:
    """(head paths, base paths) Git pairs as moved; -B breaks a rewritten path so a file moved away pairs."""
    done = subprocess.run(["git", "-C", str(ROOT), "diff", "-B", "-M", "--name-status", "-z", base, head],
                          capture_output=True)
    if done.returncode:
        raise BudgetError(done.stderr.decode(errors="replace").strip() or "git diff failed")
    fields, targets, sources, i = done.stdout.split(b"\0"), set(), set(), 0
    while i < len(fields) and fields[i]:
        # Without copy detection Git reports C only when -B broke the source: its old content moved.
        if fields[i].decode().startswith(("R", "C")):
            sources.add(fields[i + 1].decode("utf-8", "surrogateescape"))
            targets.add(fields[i + 2].decode("utf-8", "surrogateescape"))
            i += 3
        else:
            i += 2
    return targets, sources


def main(argv: list[str]) -> int:
    args, base = list(argv), "origin/main"
    if "--base" in args:
        at = args.index("--base")
        if at + 1 >= len(args):
            args.append("-")
        base = args[at + 1]
        del args[at:at + 2]
    if len(args) > 1 or any(a.startswith("-") for a in args):
        print("usage: scripts/tron budgets [<rev>] [--base <ref>]", file=sys.stderr)
        return 2
    revision = args[0] if args else "HEAD"
    try:
        head = measure(revision)
        try:
            bound = measure(base)
        except BudgetError as error:
            raise BudgetError(f"base {base} cannot be measured ({error}); pass --base <ref> with the revision "
                              "this work starts from") from error
        moved_to, moved_away = moves(bound["sha"], head["sha"])
    except BudgetError as error:
        print(f"budgets: {error}", file=sys.stderr)
        return 2
    problems, code, docs = [], 0, 0
    for path, f in sorted(head["files"].items()):
        if f["category"] not in metrics.HAND_WRITTEN or path in POLICY_OWNED or path in EXEMPT:
            continue
        lines = f["lines"]
        if f["category"] == "docs":
            budget = doc_budget(path)
            docs += lines > budget
            if lines > DOC_FACTOR * budget:
                problems.append(f"doc over {DOC_FACTOR}x budget: {path} has {lines} lines; budget is {budget}, "
                                f"limit {DOC_FACTOR * budget} (split it by owner)")
            continue
        code += lines > LINE_BUDGET
        # A moved file is not new; a file at a path whose old file moved away is.
        new = path not in moved_to and (path not in bound["files"] or path in moved_away)
        if new and f["category"] == "production" and lines > NEW_FILE_LIMIT:
            problems.append(f"new production file over {NEW_FILE_LIMIT} lines: {path} has {lines} lines "
                            "(split it by cohesive operation)")
    for line in problems:
        print(line)
    print(f"budgets: {revision} ({head['sha'][:12]}) against {base}: {code} code files over {LINE_BUDGET} lines, "
          f"{docs} docs over budget (reported); "
          + (f"{len(problems)} problem(s)" if problems else "no new production file over "
             f"{NEW_FILE_LIMIT} lines and no doc over {DOC_FACTOR}x budget"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
