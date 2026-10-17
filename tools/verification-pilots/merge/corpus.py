#!/usr/bin/env python3
"""Build the real-history merge corpus manifest (#1262 pilot).

For every two-parent commit reachable from --tip (oldest first) this records the
first parent (left), second parent (right), the single merge base, and the
historical resolved tree (oracle). Paths that need a content decision are kept:

  both-content   both sides changed differently (add/add included)
  modify-delete  one side deleted a file the other side modified
  same-side/left-only/right-only  one-sided paths whose oracle differs from the
                 side that Git would take (a manual edit inside the merge commit)
  oracle-only    neither side changed the path but the merge commit did

Run it against a scratch clone, never against a shared checkout:

  corpus.py --repo <scratch-clone> --tip <sha> --work <dir> --out <manifest.jsonl>

Blob ids are recorded so replay and scoring can read exact bytes via cat-file.
Rename detection is disabled for path classification; the number of renames
Git would detect per side is recorded so the limitation is measurable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import MERGIRAF_SYNTAX_EXTENSIONS, Git, extension_of, language_of, tree_blobs  # noqa: E402


def classify(base: Optional[str], left: Optional[str], right: Optional[str], oracle: Optional[str]) -> Optional[dict]:
    """Return a manifest entry for a path, or None when the path is trivially settled."""
    if left == right:
        kind = "same-side"
        expected = left
    elif base == left:
        kind = "right-only"
        expected = right
    elif base == right:
        kind = "left-only"
        expected = left
    elif left is None or right is None:
        kind = "modify-delete"
        expected = None
    else:
        kind = "both-content"
        expected = None

    if kind in ("both-content", "modify-delete"):
        return {"kind": kind, "expected": None}
    if left == base == right and oracle != base:
        return {"kind": "oracle-only", "expected": base}
    if oracle != expected:
        return {"kind": kind, "expected": expected, "manual_edit": True}
    return None


def side_renames(git: Git, base: Optional[str], side: str) -> int:
    if base is None:
        return 0
    text = git.text("diff-tree", "-r", "-M", "--name-status", base, side)
    return sum(1 for line in text.splitlines() if line.startswith("R"))


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--tip", required=True)
    ap.add_argument("--work", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args(argv)

    home = args.work / "home"
    home.mkdir(parents=True, exist_ok=True)
    git = Git(args.repo, home)

    merges = git.text("rev-list", "--merges", "--topo-order", "--reverse", args.tip).split()
    rows = []
    stats = {"merges": 0, "two_parent": 0, "multi_base": 0, "path_entries": 0, "kinds": {}}
    for index, merge in enumerate(merges):
        parents = git.text("rev-list", "--parents", "-n1", merge).split()[1:]
        if len(parents) != 2:
            continue
        left_commit, right_commit = parents
        bases = git.text("merge-base", "--all", left_commit, right_commit, ok=(0, 1)).split()
        if len(bases) > 1:
            stats["multi_base"] += 1
            raise SystemExit(
                "merge %s has %d merge bases; single-base classification is unsupported" % (merge, len(bases))
            )
        base = bases[0] if bases else None
        base_blobs = tree_blobs(git, base)
        left_blobs = tree_blobs(git, left_commit)
        right_blobs = tree_blobs(git, right_commit)
        oracle_blobs = tree_blobs(git, merge)

        all_paths = set(base_blobs) | set(left_blobs) | set(right_blobs) | set(oracle_blobs)
        changed = 0
        paths = []
        for path in sorted(all_paths):
            b, l, r, o = base_blobs.get(path), left_blobs.get(path), right_blobs.get(path), oracle_blobs.get(path)
            if b == l == r == o:
                continue
            changed += 1
            verdict = classify(b, l, r, o)
            if verdict is None:
                continue
            verdict.update({
                "path": path,
                "language": language_of(path),
                "extension": extension_of(path),
                "mergiraf_syntax": extension_of(path) in MERGIRAF_SYNTAX_EXTENSIONS,
                "base": b,
                "left": l,
                "right": r,
                "oracle": o,
            })
            paths.append(verdict)
            stats["kinds"][verdict["kind"]] = stats["kinds"].get(verdict["kind"], 0) + 1
        stats["path_entries"] += len(paths)
        stats["two_parent"] += 1

        subject = git.text("log", "-1", "--format=%cI%x1f%s", merge).split("\x1f", 1)
        rows.append({
            "index": len(rows),
            "merge": merge,
            "parents": [left_commit, right_commit],
            "base": base,
            "oracle_tree": git.text("rev-parse", merge + "^{tree}"),
            "committed": subject[0],
            "subject": subject[1],
            "renames": {"left": side_renames(git, base, left_commit), "right": side_renames(git, base, right_commit)},
            "changed_paths": changed,
            "paths": paths,
        })

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    digest = hashlib.sha256(args.out.read_bytes()).hexdigest()
    summary = {
        "tip": args.tip,
        "two_parent_merges": stats["two_parent"],
        "merges_with_content_decisions": sum(1 for r in rows if any(p["kind"] in ("both-content", "modify-delete") for p in r["paths"])),
        "content_decision_paths": sum(1 for r in rows for p in r["paths"] if p["kind"] in ("both-content", "modify-delete")),
        "manual_edit_paths": sum(1 for r in rows for p in r["paths"] if p.get("manual_edit")),
        "kinds": stats["kinds"],
        "renamed_side_merges": sum(1 for r in rows if r["renames"]["left"] or r["renames"]["right"]),
        "manifest_sha256": digest,
    }
    args.out.with_suffix(".summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
