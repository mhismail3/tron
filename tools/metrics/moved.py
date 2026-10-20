#!/usr/bin/env python3
"""Advisory, indentation-tolerant moved-line accounting (plan V10)."""
from __future__ import annotations

import argparse
from collections import Counter
from difflib import SequenceMatcher
import json
import sys

from metrics import BINARY_PROBE_BYTES, MetricsError, count_lines, git, renames, resolve, ROOT


FIELDS = ("moved", "movedOut", "rewritten", "changedInMove", "new", "deleted")


def lines(rev: str, path: str | None) -> list[bytes] | None:
    if path is None:
        return []
    # Read the tree entry, not the working tree; gitlinks are not text blobs.
    entry = git("ls-tree", "-z", rev, "--", ":(literal)" + path)
    if not entry or entry.split(b" ", 2)[1] != b"blob":
        return None
    blob = git("cat-file", "blob", f"{rev}:{path}")
    if b"\0" in blob[:BINARY_PROBE_BYTES]:
        return None
    return [line.lstrip(b" \t") for line in blob.split(b"\n")[:count_lines(blob)]]


def measure(base: str, head: str) -> dict:
    rows, pending = [], []
    for status, old, new in renames(base, head):
        before, after = lines(base, old), lines(head, new)
        row = {"status": status, "old": old, "path": new or old, **dict.fromkeys(FIELDS, 0),
               "binaryOrGitlink": before is None or after is None}
        removed, added = [], []
        if not row["binaryOrGitlink"]:
            for tag, old_start, old_end, new_start, new_end in SequenceMatcher(None, before, after, autojunk=False).get_opcodes():
                if tag == "equal":
                    if status == "R":
                        row["moved"] += new_end - new_start
                        row["movedOut"] += old_end - old_start
                else:
                    removed.extend(before[old_start:old_end])
                    added.extend(after[new_start:new_end])
        rows.append(row)
        pending.append((Counter(removed), Counter(added)))

    # Pair each removed/added line at most once across the whole change. Like
    # color-moved=plain this is text matching, not proof of semantic identity.
    removed_total, added_total = Counter(), Counter()
    for removed, added in pending:
        removed_total.update(removed)
        added_total.update(added)
    available_out = removed_total & added_total
    available_in = available_out.copy()
    for row, (removed, added) in zip(rows, pending):
        for counts, available, field in ((removed, available_out, "movedOut"), (added, available_in, "moved")):
            matched = counts & available
            row[field] += sum(matched.values())
            counts.subtract(matched)
            available.subtract(matched)
        deleted, new = sum(removed.values()), sum(added.values())  # Counter.total() needs Python 3.10
        row["rewritten"] = min(deleted, new)
        row["changedInMove"] = row["rewritten"] if row["status"] == "R" else 0
        row["deleted"] = deleted - row["rewritten"]
        row["new"] = new - row["rewritten"]
    return {"schema": "tron.moved-lines.v1", "base": base, "head": head, "files": rows,
            "totals": {field: sum(row[field] for row in rows) for field in FIELDS}}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron measure", description=__doc__)
    parser.add_argument("base", help="base commit")
    parser.add_argument("head", nargs="?", default="HEAD", help="head commit (default HEAD)")
    args = parser.parse_args(argv)
    try:
        base, head = resolve(args.base), resolve(args.head)
        result = measure(base, head)
        output = ROOT / "test-results" / "measure" / f"{base}-{head}.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print("Moved-lines (advisory): " + ", ".join(f"{key}={value}" for key, value in result["totals"].items()))
        print(f"report: {output.relative_to(ROOT)}")
        return 0
    except (MetricsError, OSError) as error:
        print(f"measure: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
