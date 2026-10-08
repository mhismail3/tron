"""Typed public issue-comment command for the work protocol."""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from gh import Gh, GhError

MAX_COMMENT_BYTES = 64 * 1024


def post(gh: Gh, repo: Path, config: dict, number: int, body_file: Path) -> int:
    if number <= 0:
        raise GhError("issue number must be positive")
    try:
        body = body_file.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise GhError("could not read the issue comment body file") from error
    if not body.strip():
        raise GhError("issue comment body must not be empty")
    session = os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID")
    if not session or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", session):
        raise GhError("a valid work session ID is required for issue comments")
    body = body.rstrip() + f"\n\n<!-- work:comment session={session} -->\n"
    if len(body.encode("utf-8")) > MAX_COMMENT_BYTES:
        raise GhError("issue comment exceeds the 64 KiB bound")

    command = config.get("verify", {}).get("scrubCommand")
    if not isinstance(command, str) or not command.strip():
        raise GhError("public issue comments require the configured privacy guard")
    checked = subprocess.run(
        ["bash", "-c", command], cwd=repo, input=body,
        capture_output=True, text=True,
    )
    if checked.returncode:
        # Guard output may quote personal data. Do not copy it to terminal,
        # the audit log, or GitHub; the caller can inspect the private source.
        raise GhError("issue comment refused by the privacy guard")
    gh.run("issue", "comment", str(number), "--body-file", "-", stdin=body)
    print(f"commented on issue #{number}")
    return 0
