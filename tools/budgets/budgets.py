#!/usr/bin/env python3
"""File-size and doc budgets with shrink-only manifest exceptions (tools/budgets/README.md)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "metrics"))
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import metrics  # noqa: E402  (the one classification and line-count authority)
import ownership  # noqa: E402  (the one module and exception authority)

LINE_BUDGET = metrics.SIZE_THRESHOLD
# The charter's two root budgets are owned by scripts/check-documentation-policy.py.
POLICY_OWNED = {"README.md", "AGENTS.md"}
# Plan §0: the restructure plan is exempt from doc budgets until epic exit (M6), when it is
# deleted. Its steward records decisions in it, so a shrink-only exception would refuse them.
EXEMPT = {"docs/restructure/plan.md"}


class BudgetError(Exception):
    pass


def budget_of(path: str, category: str) -> tuple[str, int] | None:
    """(kind, limit) for a hand-written file (plan §3 M2 file size, §5.6 doc budgets)."""
    if category not in metrics.HAND_WRITTEN or path in POLICY_OWNED or path in EXEMPT:
        return None
    if category != "docs":
        return "lines", LINE_BUDGET
    parts = path.split("/")
    if parts[-1] == "README.md":
        return "doc", 200 if len(parts) == 3 and parts[0] == "packages" else 150
    return "doc", 300


def measure(revision: str) -> tuple[dict, dict]:
    """Over-budget files {path: (kind, lines, limit)} and exceptions {(path, kind): module} at a revision."""
    try:
        sha = metrics.resolve(revision)
        files = metrics.read_tree(sha)
        owned, errors = ownership.check(sha)
    except (metrics.MetricsError, ownership.GitError) as error:
        raise BudgetError(str(error)) from error
    if errors:
        raise BudgetError(f"ownership at {revision} has {len(errors)} violation(s); fix them first "
                          f"(scripts/tron ownership {revision})")
    over = {}
    for f in files:
        budget = budget_of(f["path"], f["category"])
        if budget and f["lines"] > budget[1]:
            over[f["path"]] = (budget[0], f["lines"], budget[1])
    lines = {f["path"]: f["lines"] for f in files}
    exceptions = {(e["path"], e["budget"]): key for key, module in owned["modules"].items()
                  for e in module["exceptions"]}
    return {"over": over, "lines": lines, "sha": sha}, exceptions


def renames(base: str, head: str) -> dict:
    """New path -> base path for files Git pairs as renamed between the two revisions."""
    # -B breaks a rewritten path so a file moved away from it pairs with its new name.
    done = subprocess.run(["git", "-C", str(ROOT), "diff", "-B", "-M", "--name-status", "-z", base, head],
                          capture_output=True)
    if done.returncode:
        raise BudgetError(done.stderr.decode(errors="replace").strip() or "git diff failed")
    fields, found, i = done.stdout.split(b"\0"), {}, 0
    while i < len(fields) and fields[i]:
        status = fields[i].decode()
        # Without copy detection Git reports C only when -B broke the source (rewritten in place):
        # its old content moved, so both R and C are moves.
        if status.startswith(("R", "C")):
            found[fields[i + 2].decode("utf-8", "surrogateescape")] = fields[i + 1].decode("utf-8", "surrogateescape")
            i += 3
        else:
            i += 2
    return found


def checker_on_main() -> bool:
    done = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", "origin/main:tools/budgets/budgets.py"],
                          capture_output=True)
    return done.returncode == 0


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
        head, exceptions = measure(revision)
        try:
            bound, bound_exceptions = measure(base)
        except BudgetError as error:
            raise BudgetError(f"base {base} cannot be measured ({error}); pass --base <ref> with the revision "
                              "this work starts from") from error
        moved = renames(bound["sha"], head["sha"])
    except BudgetError as error:
        print(f"budgets: {error}", file=sys.stderr)
        return 2
    problems = []
    for path, (kind, lines, limit) in sorted(head["over"].items()):
        if (path, kind) not in exceptions:
            problems.append(f"over budget: {path} has {lines} lines; {kind} budget is {limit} "
                            "(split it; exceptions are never added)")
    # Only the change that introduces this checker may seed exceptions; afterwards the base bounds them,
    # even once the base has none left. Once origin/main has the checker, no --base can reopen seeding.
    introduced = "tools/budgets/budgets.py" not in bound["lines"] and not checker_on_main()
    renamed_away = set(moved.values())
    for (path, kind), module in sorted(exceptions.items()):
        if path not in head["over"] or head["over"][path][0] != kind:
            state = f"{head['lines'][path]} lines" if path in head["lines"] else "deleted"
            problems.append(f"stale exception: {path} ({kind}) in {module} is within budget ({state}); remove it")
            continue
        # A path whose base file was renamed away holds a new file; it inherits nothing.
        origin = moved.get(path) or (path if path not in renamed_away else None)
        if introduced:
            continue
        if origin is None or (origin, kind) not in bound_exceptions or origin not in bound["lines"]:
            problems.append(f"new exception: {path} ({kind}) in {module} is not excepted at {base}; split the "
                            "file instead")
        elif head["lines"][path] > bound["lines"][origin]:
            problems.append(f"grew: {path} ({kind}) {bound['lines'][origin]} -> {head['lines'][path]} lines "
                            f"(excepted files may only shrink)")
    for line in problems:
        print(line)
    code = sum(1 for kind, _, _ in head["over"].values() if kind == "lines")
    print(f"budgets: {revision} ({head['sha'][:12]}): {code} code files over {LINE_BUDGET} lines, "
          f"{len(head['over']) - code} docs over budget, {len(exceptions)} exceptions"
          + (f" (seeded; {base} has no budget checker)" if introduced else "") + "; "
          + (f"{len(problems)} problem(s)" if problems else "every file within budget or excepted"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
