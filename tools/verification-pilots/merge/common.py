"""Shared helpers for the merge-conflict corpus pilot (#1262).

Standard library only. Every Git process runs with an isolated HOME/TMPDIR and
with global and system configuration disabled; behavior-changing settings are
passed explicitly with -c so each arm's configuration is visible in its command.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Dict, Optional, Tuple

# Matches the author's global configuration (merge.conflictstyle=diff3) so that
# rerere preimage hashes are comparable with the primary checkout's rr-cache.
BASE_GIT_CONFIG = (
    "merge.conflictStyle=diff3",
    "user.name=corpus-replay",
    "user.email=corpus-replay@invalid",
    "commit.gpgsign=false",
    "core.autocrlf=false",
    "gc.auto=0",
)


def isolated_env(home: Path) -> Dict[str, str]:
    tmp = home / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "TMPDIR": str(tmp),
        "LC_ALL": "C",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }


class Git:
    """Runs git inside one repository (the scratch clone, never a shared checkout)."""

    def __init__(self, repo: Path, home: Path, extra_config: Tuple[str, ...] = ()):
        self.repo = repo
        self.env = isolated_env(home)
        self.prefix = ["git", "-C", str(repo)]
        for item in BASE_GIT_CONFIG + tuple(extra_config):
            self.prefix += ["-c", item]

    def run(self, *args: str, ok: Tuple[int, ...] = (0,), stdin: Optional[bytes] = None) -> subprocess.CompletedProcess:
        proc = subprocess.run(
            self.prefix + list(args),
            env=self.env,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode not in ok:
            raise RuntimeError(
                "git %s failed rc=%d: %s" % (" ".join(args), proc.returncode, proc.stderr.decode("utf-8", "replace")[-800:])
            )
        return proc

    def text(self, *args: str, ok: Tuple[int, ...] = (0,)) -> str:
        return self.run(*args, ok=ok).stdout.decode("utf-8", "replace").strip()


class BlobReader:
    """Long-running `git cat-file --batch` reader; returns None for missing objects."""

    def __init__(self, git: Git):
        self.proc = subprocess.Popen(
            git.prefix + ["cat-file", "--batch"],
            env=git.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )

    def read(self, oid: Optional[str]) -> Optional[bytes]:
        if oid is None:
            return None
        self.proc.stdin.write((oid + "\n").encode())
        self.proc.stdin.flush()
        header = self.proc.stdout.readline().decode().split()
        if header[-1] == "missing":
            raise RuntimeError("missing object %s" % oid)
        size = int(header[2])
        data = self.proc.stdout.read(size)
        self.proc.stdout.read(1)  # trailing newline after each object
        return data

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()


def tree_blobs(git: Git, commit: Optional[str]) -> Dict[str, str]:
    """Map path -> blob oid for every regular blob in a commit (no rename detection)."""
    if commit is None:
        return {}
    out = git.run("ls-tree", "-r", "-z", "--full-tree", commit).stdout
    blobs: Dict[str, str] = {}
    for record in out.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        _mode, kind, oid = meta.decode().split()
        if kind == "blob":
            blobs[path.decode("utf-8", "surrogateescape")] = oid
    return blobs


LANGUAGE_BY_EXTENSION = {
    "swift": "swift",
    "ts": "ts-js", "tsx": "ts-js", "mts": "ts-js", "cts": "ts-js",
    "js": "ts-js", "jsx": "ts-js", "mjs": "ts-js", "cjs": "ts-js",
    "py": "python",
    "sh": "shell", "bash": "shell",
    "md": "markdown",
    "json": "json",
    "rs": "rust",
    "pbxproj": "xcode-config", "xcconfig": "xcode-config", "xctestplan": "xcode-config",
    "plist": "xcode-config", "entitlements": "xcode-config",
}

# Extensions with a syntax-aware Mergiraf language (`mergiraf languages`, v0.20.0).
# Other files fall back to Mergiraf's line-based merge.
MERGIRAF_SYNTAX_EXTENSIONS = frozenset({
    "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "json", "md", "py", "rs",
    "sh", "bash", "yml", "yaml", "toml", "xml", "html", "htm", "properties", "ini",
})


def extension_of(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def language_of(path: str) -> str:
    return LANGUAGE_BY_EXTENSION.get(extension_of(path), "other")
