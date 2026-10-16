"""Append-only JSONL ledgers under `<git common dir>/work/` (README.md#ledgers, #1103).

One writer per ledger: `gate/metrics.jsonl` (gate.py, one row per finished shard),
`land/events.jsonl` (land.py, one row per landing event) and `heavy/events.jsonl`
(heavy.py, one row per acquire and release). `gate report` reads all three.

Every row carries its time, the owner session and the worktree path, so a row links
back to the worker transcript and task that produced it. `purpose` separates real
work from measurement: a benchmark harness sets `TRON_GATE_PURPOSE=benchmark`, and
`gate report` counts its rows apart instead of mixing them into the baseline (the
10-15 baseline had 110 benchmark-worktree rows mixed in).
"""
from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator


def common_dir(root: Path) -> Path:
    done = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=root,
                          capture_output=True, text=True, check=True)
    return Path(done.stdout.strip())


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def context(root: Path) -> dict:
    """The fields every ledger row shares."""
    return {"at": now(), "session": os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID") or "",
            "worktreePath": str(root), "purpose": os.environ.get("TRON_GATE_PURPOSE") or "work"}


def append(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # One write of one line under O_APPEND: concurrent writers never interleave a row.
    with path.open("a") as stream:
        stream.write(json.dumps(row, sort_keys=True) + "\n")


def rows(path: Path) -> Iterator[dict]:
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            yield row
