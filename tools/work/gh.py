"""The only boundary between the work tooling and GitHub: the gh CLI."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Optional

# Agent shells can inherit a PATH without Homebrew; these are gh's standard
# install locations, checked only after WORK_GH and PATH.
_FALLBACKS = ("/opt/homebrew/bin/gh", "/usr/local/bin/gh")


class GhError(RuntimeError):
    pass


def resolve_gh() -> str:
    explicit = os.environ.get("WORK_GH")
    if explicit:
        if not os.access(explicit, os.X_OK):
            raise GhError(f"WORK_GH is not executable: {explicit}")
        return explicit
    found = shutil.which("gh")
    if found:
        return found
    for candidate in _FALLBACKS:
        if os.access(candidate, os.X_OK):
            return candidate
    raise GhError("GitHub CLI not found; install gh or set WORK_GH")


class Gh:
    def __init__(self, cwd: Path) -> None:
        self.binary = resolve_gh()
        self.cwd = cwd

    def run(self, *args: str, stdin: Optional[str] = None) -> str:
        completed = subprocess.run(
            [self.binary, *args],
            cwd=self.cwd,
            input=stdin,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise GhError(f"gh {' '.join(args[:3])} failed: {detail}")
        return completed.stdout

    def graphql(self, query: str, **variables: Any) -> dict:
        body = json.dumps({"query": query, "variables": variables})
        response = json.loads(self.run("api", "graphql", "--input", "-", stdin=body))
        if response.get("errors"):
            raise GhError("GraphQL: " + "; ".join(error.get("message", "?") for error in response["errors"]))
        return response["data"]

    def rest(self, method: str, path: str, body: Optional[dict] = None) -> Any:
        args = ["api", "-X", method, path]
        if body is not None:
            args += ["--input", "-"]
        output = self.run(*args, stdin=json.dumps(body) if body is not None else None)
        return json.loads(output) if output.strip() else None

    def rest_pages(self, path: str) -> list:
        # --slurp wraps every page in one outer array.
        pages = json.loads(self.run("api", "--paginate", "--slurp", path))
        return [item for page in pages for item in page]
