#!/usr/bin/env python3
"""Replay content decisions from the corpus manifest through one merge arm (#1262 pilot).

Arms:
  git-plain     real `git merge` in the scratch clone, rerere disabled, each merge independent
  git-rerere    real `git merge` with rerere enabled; the cache starts empty (--cache cold)
                or from a copy of an existing rr-cache (--cache seeded:<dir>), learning in
                chronological order from the simulated human resolutions of earlier merges
  mergiraf      per-path driver emulation: `mergiraf merge base left right -p path` for each
                both-content path (no git merge, no repo configuration touched)

Human resolution is simulated as writing the historical resolved content (the oracle
proxy) into every path the arm left unresolved, then committing. Exact-content equality
with the oracle is an oracle proxy only; differing clean outputs are not labelled wrong here.

  replay.py --repo <scratch-clone> --manifest <manifest.jsonl> --work <dir> \
            --arm {git-plain,git-rerere,mergiraf} [--cache cold|seeded:<dir>] \
            [--mergiraf <binary>] --out <arm.jsonl> [--limit N]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import BlobReader, Git, tree_blobs  # noqa: E402

CONFLICT_MARKER = b"<<<<<<<"


def load_manifest(path: Path) -> List[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def count_markers(data: Optional[bytes]) -> int:
    if data is None:
        return 0
    return sum(1 for line in data.split(b"\n") if line.startswith(CONFLICT_MARKER))


def git_arm(args, rows: List[dict], git: Git, blobs: BlobReader) -> List[dict]:
    rerere = args.arm == "git-rerere"
    rr_cache = git.repo / ".git" / "rr-cache"
    if rerere:
        shutil.rmtree(rr_cache, ignore_errors=True)
        if args.cache.startswith("seeded:"):
            shutil.copytree(args.cache.split(":", 1)[1], rr_cache)
    git_arm_config = ["rerere.enabled=" + ("true" if rerere else "false")]
    git = Git(git.repo, Path(git.env["HOME"]), tuple(git_arm_config))
    out = []
    for row in rows:
        started = time.monotonic()
        git.run("reset", "-q", "--hard")
        git.run("clean", "-ffdxq")
        git.run("checkout", "-q", "-f", "--detach", row["parents"][0])
        merge = git.run("merge", "--no-ff", "--no-commit", "-q", row["parents"][1], ok=(0, 1))
        unmerged = sorted({
            line.split(b"\t", 1)[1].decode("utf-8", "surrogateescape")
            for line in git.run("ls-files", "-u", "-z").stdout.split(b"\0") if line
        })
        staged = {}
        for line in git.run("ls-files", "-s", "-z").stdout.split(b"\0"):
            if line:
                meta, path = line.split(b"\t", 1)
                if meta.split()[2] == b"0":
                    staged[path.decode("utf-8", "surrogateescape")] = meta.split()[1].decode()
        by_path = {p["path"]: p for p in row["paths"]}
        oracle_blobs = tree_blobs(git, row["merge"])
        results = []
        for path in sorted(set(unmerged) | set(by_path)):
            entry = by_path.get(path, {"kind": "git-only"})
            oracle = oracle_blobs.get(path)
            if path in unmerged:
                worktree = git.repo / path
                content = worktree.read_bytes() if worktree.is_file() else None
                markers = count_markers(content)
                applied = bool(rerere and content is not None and markers == 0 and entry["kind"] == "both-content")
                auto = {"status": "unmerged", "markers": markers, "rerere_applied": applied}
                if applied and oracle is not None:
                    auto["rerere_matches_oracle"] = content == blobs.read(oracle)
                auto_oid = None
            else:
                auto_oid = staged.get(path)
                auto = {"status": "clean", "markers": 0, "rerere_applied": False}
            auto_equal = (auto_oid == oracle) if auto["status"] == "clean" else None
            results.append({
                "path": path,
                "kind": entry["kind"],
                "oracle": oracle,
                **auto,
                "auto_equals_oracle": auto_equal,
            })
        # Simulated human resolution: write the historical content into every unmerged path.
        kept = [p for p in unmerged if oracle_blobs.get(p) is not None]
        for path in unmerged:
            oracle = oracle_blobs.get(path)
            if oracle is None:
                git.run("rm", "-q", "-f", "--ignore-unmatch", "--", path)
            else:
                target = git.repo / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(blobs.read(oracle))
        if kept:
            git.run("add", "--", *kept)
        if unmerged:
            git.run("commit", "-q", "-m", "corpus replay %s" % row["merge"])
            tree = git.text("rev-parse", "HEAD^{tree}")
        else:
            tree = git.text("write-tree")
        git.run("reset", "-q", "--hard", ok=(0,))
        out.append({
            "index": row["index"],
            "merge": row["merge"],
            "git_rc": merge.returncode,
            "unmerged_paths": len(unmerged),
            "final_tree_equals_oracle": tree == row["oracle_tree"],
            "paths": results,
            "seconds": round(time.monotonic() - started, 3),
        })
    return out


def mergiraf_arm(args, rows: List[dict], blobs: BlobReader) -> List[dict]:
    scratch = Path(tempfile.mkdtemp(prefix="mergiraf-", dir=args.work))
    out = []
    try:
        for row in rows:
            started = time.monotonic()
            results = []
            for entry in row["paths"]:
                if entry["kind"] == "modify-delete":
                    results.append({"path": entry["path"], "kind": entry["kind"], "status": "unmerged",
                                    "markers": 0, "oracle": entry["oracle"], "auto_equals_oracle": None,
                                    "tool_rc": None, "mergiraf_syntax": entry["mergiraf_syntax"]})
                    continue
                if entry["kind"] != "both-content":
                    results.append({"path": entry["path"], "kind": entry["kind"], "status": "clean",
                                    "markers": 0, "oracle": entry["oracle"],
                                    "auto_equals_oracle": entry.get("expected") == entry["oracle"],
                                    "tool_rc": None, "mergiraf_syntax": entry["mergiraf_syntax"]})
                    continue
                files = {}
                for role in ("base", "left", "right"):
                    files[role] = scratch / ("%s-%s" % (role, row["index"]))
                    files[role].write_bytes(blobs.read(entry[role]) if entry[role] else b"")
                output = scratch / ("out-%d" % row["index"])
                proc = subprocess.run(
                    [args.mergiraf, "merge", str(files["base"]), str(files["left"]), str(files["right"]),
                     "-p", entry["path"], "-o", str(output)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "HOME": str(scratch), "TMPDIR": str(scratch)},
                )
                if proc.returncode not in (0, 1):
                    raise RuntimeError("mergiraf failed rc=%d on %s: %s" % (proc.returncode, entry["path"], proc.stderr[-400:]))
                merged = output.read_bytes()
                markers = count_markers(merged)
                status = "clean" if proc.returncode == 0 else "unmerged"
                oracle_bytes = blobs.read(entry["oracle"]) if entry["oracle"] else None
                results.append({
                    "path": entry["path"],
                    "kind": entry["kind"],
                    "status": status,
                    "markers": markers,
                    "oracle": entry["oracle"],
                    "auto_equals_oracle": (merged == oracle_bytes) if status == "clean" else None,
                    "tool_rc": proc.returncode,
                    "mergiraf_syntax": entry["mergiraf_syntax"],
                })
                for path in files.values():
                    path.unlink(missing_ok=True)
                output.unlink(missing_ok=True)
            out.append({
                "index": row["index"],
                "merge": row["merge"],
                "paths": results,
                "seconds": round(time.monotonic() - started, 3),
            })
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return out


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--work", required=True, type=Path)
    ap.add_argument("--arm", required=True, choices=("git-plain", "git-rerere", "mergiraf"))
    ap.add_argument("--cache", default="cold")
    ap.add_argument("--mergiraf", type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--limit", type=int, default=0, help="replay only the first N content-decision merges")
    args = ap.parse_args(argv)

    rows = [r for r in load_manifest(args.manifest) if any(p["kind"] in ("both-content", "modify-delete") for p in r["paths"])]
    if args.limit:
        rows = rows[: args.limit]
    home = args.work / "home"
    home.mkdir(parents=True, exist_ok=True)
    git = Git(args.repo, home)
    blobs = BlobReader(git)
    try:
        if args.arm == "mergiraf":
            if args.mergiraf is None:
                raise SystemExit("--mergiraf <binary> is required for the mergiraf arm")
            results = mergiraf_arm(args, rows, blobs)
        else:
            results = git_arm(args, rows, git, blobs)
    finally:
        blobs.close()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        for row in results:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    print("%s: %d merges replayed -> %s" % (args.arm, len(results), args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
