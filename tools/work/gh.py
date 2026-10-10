"""The audited boundary between work tooling and the GitHub CLI."""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Optional

# Agent shells can inherit a PATH without Homebrew; these are gh's standard
# install locations, checked only after WORK_GH and PATH.
_FALLBACKS = ("/opt/homebrew/bin/gh", "/usr/local/bin/gh")
AUDIT_MAX_BYTES = 16 * 1024 * 1024
_AUDIT_RESERVE_BYTES = 128


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


def _audit_directory(cwd: Path) -> Path:
    completed = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=cwd, capture_output=True, text=True,
    )
    if completed.returncode:
        raise GhError("cannot locate the repository's private Git metadata for the write audit")
    return Path(completed.stdout.strip()) / "work"


def _write_kind(args: tuple[str, ...]) -> Optional[str]:
    if len(args) >= 2 and args[:2] == ("issue", "close") and "--comment" in args:
        # gh combines comment creation and closure; one sub-write may commit
        # even when the combined command reports a later failure.
        return "issue.close.compound"
    if len(args) >= 2 and args[0] in {"issue", "pr", "project", "label", "release", "repo"}:
        verbs = {
            "issue": {"comment", "edit", "close", "reopen", "create", "delete"},
            "pr": {"comment", "edit", "close", "reopen", "create", "merge", "ready"},
            "project": {"item-add", "item-edit", "item-delete", "field-create", "field-delete"},
            "label": {"create", "edit", "delete"},
            "release": {"create", "edit", "delete", "upload"},
            "repo": {"edit", "sync"},
        }
        if args[1] in verbs[args[0]]:
            return f"{args[0]}.{args[1]}"
    if args and args[0] == "api":
        method = "GET"
        for index, argument in enumerate(args[:-1]):
            if argument in ("-X", "--method"):
                method = args[index + 1].upper()
                break
        if method != "GET":
            return f"api.{method}"
    return None


def _failed_status(completed: subprocess.CompletedProcess, operation: str) -> str:
    # Compound CLI calls (notably issue close --comment) can commit one
    # mutation before another is rejected, so their failure is never certain.
    if ".compound" in operation:
        return "uncertain"
    # A single request explicitly rejected with HTTP 4xx is a known failure.
    # Transport and opaque errors may follow a server commit.
    text = (completed.stderr or "") + "\n" + (completed.stdout or "")
    if re.search(r"\bHTTP\s+4\d\d\b|\bGraphQL:.*(?:validation|syntax|not authorized|forbidden)", text, re.I):
        return "failed"
    return "uncertain"


class Gh:
    def __init__(self, cwd: Path) -> None:
        self.binary = resolve_gh()
        self.cwd = cwd
        self._audit_dir: Optional[Path] = None

    def _audit_location(self) -> tuple[Path, Path]:
        if self._audit_dir is None:
            self._audit_dir = _audit_directory(self.cwd)
        self._audit_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = os.lstat(self._audit_dir)
        if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid():
            raise GhError("local GitHub write audit directory is not privately owned")
        os.chmod(self._audit_dir, 0o700)
        return self._audit_dir / "github-writes.jsonl", self._audit_dir / "github-writes.lock"

    @contextmanager
    def taxonomy_labels_lock(self):
        """Serialize taxonomy read-modify-writes across linked worktrees."""
        audit_path, _ = self._audit_location()
        # One fixed lock avoids a persistent per-issue lock-file registry.
        lock_path = audit_path.with_name("issue-label-taxonomy.lock")
        fd = self._open_private(lock_path, os.O_CREAT | os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    @staticmethod
    def _open_private(path: Path, flags: int, mode: int = 0o600) -> int:
        fd = os.open(path, flags | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0), mode)
        details = os.fstat(fd)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
            os.close(fd)
            raise GhError("local GitHub write audit file is not privately owned")
        os.fchmod(fd, mode)
        return fd

    def _with_audit_lock(self, action):
        path, lock_path = self._audit_location()
        fd = self._open_private(lock_path, os.O_CREAT | os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            return action(path)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def _begin_write(self, operation: str) -> str:
        record_id = uuid.uuid4().hex
        record = {
            "id": record_id,
            "at": time.time_ns(),
            "event": "attempt",
            "operation": operation,
            "status": "attempted",
        }
        line = (json.dumps(record, separators=(",", ":")) + "\n").encode()

        def append(path: Path) -> None:
            flags = os.O_CREAT | os.O_APPEND | os.O_WRONLY
            fd = self._open_private(path, flags)
            try:
                current = os.fstat(fd).st_size
                reserved = 0
                if current:
                    scan_fd = self._open_private(path, os.O_RDONLY)
                    with os.fdopen(scan_fd, "rb") as stream:
                        pending = set()
                        for old_line in stream:
                            try:
                                old = json.loads(old_line)
                            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                                raise GhError("local GitHub write audit contains an unreadable record") from error
                            if old.get("event") == "attempt":
                                pending.add(old["id"])
                            elif old.get("event") == "result":
                                pending.discard(old["id"])
                        reserved = len(pending) * _AUDIT_RESERVE_BYTES
                if current + reserved + len(line) + _AUDIT_RESERVE_BYTES > AUDIT_MAX_BYTES:
                    raise GhError("local GitHub write audit is full; no GitHub write was attempted")
                view = memoryview(line)
                while view:
                    count = os.write(fd, view)
                    view = view[count:]
                os.fsync(fd)
            finally:
                os.close(fd)
        self._with_audit_lock(append)
        return record_id

    def _finish_write(self, record_id: str, status: str) -> None:
        record = {"id": record_id, "at": time.time_ns(), "event": "result", "status": status}
        line = (json.dumps(record, separators=(",", ":")) + "\n").encode()

        def append_result(path: Path) -> None:
            fd = self._open_private(path, os.O_APPEND | os.O_WRONLY)
            try:
                view = memoryview(line)
                while view:
                    count = os.write(fd, view)
                    view = view[count:]
                os.fsync(fd)
            finally:
                os.close(fd)
        self._with_audit_lock(append_result)

    def _exec(self, *args: str, stdin: Optional[str] = None,
              operation_override: Optional[str] = None) -> subprocess.CompletedProcess:
        operation = operation_override or _write_kind(args)
        record_id = self._begin_write(operation) if operation else None
        try:
            completed = subprocess.run(
                [self.binary, *args], cwd=self.cwd, input=stdin,
                capture_output=True, text=True,
            )
        except BaseException:
            if record_id:
                self._finish_write(record_id, "uncertain")
            raise
        if record_id:
            status = "succeeded" if completed.returncode == 0 else _failed_status(completed, operation)
            try:
                self._finish_write(record_id, status)
            except BaseException as error:
                raise GhError("GitHub request outcome is uncertain because its local audit could not be completed") from error
        return completed

    def run(self, *args: str, stdin: Optional[str] = None) -> str:
        completed = self._exec(*args, stdin=stdin)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise GhError(f"gh {' '.join(args[:3])} failed: {detail}")
        return completed.stdout

    def graphql(self, query: str, missing_ok: bool = False, **variables: Any) -> dict:
        """Run a query; with missing_ok, NOT_FOUND errors below a top-level field leave that field null."""
        body = json.dumps({"query": query, "variables": variables})
        operation = "graphql.mutation" if re.search(r"\bmutation\b", query) else None
        completed = self._exec("api", "graphql", "--input", "-", stdin=body,
                               operation_override=operation)
        # gh exits non-zero whenever the response carries errors, but still
        # prints the response; anything unparseable is a transport failure.
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError:
            response = {}
        if not isinstance(response, dict) or response.get("data") is None:
            detail = completed.stderr.strip() or completed.stdout.strip()
            raise GhError(f"gh api graphql failed: {detail}")
        errors = [e for e in response.get("errors") or []
                  if not (missing_ok and e.get("type") == "NOT_FOUND" and len(e.get("path") or []) > 1)]
        if errors:
            raise GhError("GraphQL: " + "; ".join(e.get("message", "?") for e in errors))
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
