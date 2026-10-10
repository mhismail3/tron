"""`work verify`: the fast local gate `land` runs on the tree it is about to push (README.md, `verify`).

The checks follow the paths the branch changes against `<remote>/<base>`. Passing
trees are remembered by tree hash and check set, so re-running on an unchanged tree
costs nothing. Integration and end-to-end runs are named by the caller with `--tests`.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

# Two checks at a time: a shared Mac runs other agents and the live Gateway too.
CONCURRENCY = 2
EXCERPT_LINES = 40

_GATEWAY = "packages/gateway"
_RELAY = "packages/push-relay"
_IOS = "packages/ios-app/"
_MAC = "packages/mac-app/"
_SCRIPT_SUFFIXES = {".py": "python", ".mjs": "node", ".js": "node", ".sh": "shell"}
_TEST_FILE = re.compile(r"\.(test|spec)\.(ts|tsx|mts|mjs|js)$")
_SOURCE_FILE = re.compile(r"\.(ts|tsx|mts|mjs|js)$")


class VerifyError(RuntimeError):
    pass


@dataclass(frozen=True)
class Check:
    name: str
    command: str


@dataclass
class Result:
    check: Check
    exit_code: int
    seconds: float
    log: Path


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
    if completed.returncode != 0:
        raise VerifyError(f"git {' '.join(args[:2])} failed: {completed.stderr.strip()}")
    return completed.stdout


def _git_dir(repo: Path) -> Path:
    return Path(_git(repo, "rev-parse", "--path-format=absolute", "--git-dir").strip())


def dirty_paths(repo: Path) -> List[str]:
    return _git(repo, "status", "--porcelain", "--untracked-files=all").splitlines()


def branch_changes(repo: Path, base_ref: str) -> tuple[str, List[str]]:
    """(the merge-base with `base_ref`, the paths the committed branch changes against it)."""
    merge_base = _git(repo, "merge-base", base_ref, "HEAD").strip()
    output = _git(repo, "diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD")
    return merge_base, [path for path in output.split("\0") if path]


def _install(package: str, lock_changed: bool, root: Path) -> str:
    """`npm ci` only when the lockfile changed or the package has no installed tree; run inside the package."""
    if lock_changed or not (root / package / "node_modules").is_dir():
        return "npm ci --no-audit --no-fund"
    return "true"


def _script_kind(root: Path, relative: str) -> Optional[str]:
    """python, node or shell when a changed file is a script with a syntax check, else None.

    Extensionless files count only under scripts/, where the shebang names the language.
    """
    path = Path(relative)
    kind = _SCRIPT_SUFFIXES.get(path.suffix)
    if kind is None and not path.suffix and path.parts[:1] == ("scripts",):
        first = (root / path).read_text(errors="replace").splitlines()[:1]
        shebang = first[0] if first else ""
        if re.search(r"^#!.*\b(ba|z)?sh\b", shebang):
            kind = "shell"
        elif re.search(r"^#!.*\bpython3?\b", shebang):
            kind = "python"
    return kind


def plan(root: Path, changed: List[str], tests: List[str], merge_base: str) -> List[Check]:
    """The checks the changed paths require, in the order they are reported."""
    existing = [path for path in changed if (root / path).is_file()]
    checks = [
        Check("privacy", "scripts/personal-info-guard.sh"),
        Check("whitespace", f"git diff --check {merge_base} HEAD"),
    ]
    gateway = [p[len(_GATEWAY) + 1:] for p in changed if p.startswith(f"{_GATEWAY}/")]
    if gateway:
        lock_changed = f"{_GATEWAY}/package-lock.json" in changed
        commands = [_install(_GATEWAY, lock_changed, root), "npm run check"]
        sources = [p for p in gateway if (root / _GATEWAY / p).is_file()
                   and _SOURCE_FILE.search(p) and not _TEST_FILE.search(p)]
        test_files = [p for p in gateway if (root / _GATEWAY / p).is_file() and _TEST_FILE.search(p)]
        # Related tests cover the changed sources; changed test files run directly.
        # Each config only picks up the files it includes, so the pair stays exact.
        for config in ("", "--config vitest.nested.config.ts "):
            if sources:
                commands.append(f"npx vitest related --run --passWithNoTests --maxWorkers=2 {config}"
                                + " ".join(shlex.quote(p) for p in sources))
            if test_files:
                commands.append(f"npx vitest run --passWithNoTests --maxWorkers=2 {config}"
                                + " ".join(shlex.quote(p) for p in test_files))
        checks.append(Check("gateway", f"cd {_GATEWAY} && " + " && ".join(commands)))
    if any(p.startswith(f"{_RELAY}/") for p in changed):
        lock_changed = f"{_RELAY}/package-lock.json" in changed
        checks.append(Check("push-relay", f"cd {_RELAY} && {_install(_RELAY, lock_changed, root)} && "
                                          "npm run check && npm run build"))
    if any(p.startswith(_IOS) for p in changed):
        checks.append(Check("ios", "scripts/tron-ios-test build"))
    if any(p.startswith(_MAC) for p in changed):
        checks.append(Check("mac", "scripts/tron mac generate && cd packages/mac-app && xcodebuild build "
                                   "-project TronMac.xcodeproj -scheme TronMac -configuration Debug "
                                   "-destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData"))
    syntax: dict = {"python": [], "node": [], "shell": []}
    for path in existing:
        kind = _script_kind(root, path)
        if kind:
            syntax[kind].append(shlex.quote(path))
    syntax_commands = []
    if syntax["python"]:
        syntax_commands.append("python3 -B -c 'import ast,sys\n"
                               "for p in sys.argv[1:]: ast.parse(open(p, \"rb\").read(), p)' "
                               + " ".join(syntax["python"]))
    for path in syntax["node"]:
        syntax_commands.append(f"node --check {path}")
    for path in syntax["shell"]:
        syntax_commands.append(f"bash -n {path}")
    if syntax_commands:
        checks.append(Check("syntax", " && ".join(syntax_commands)))
    for index, command in enumerate(tests, 1):
        checks.append(Check(f"test-{index}", command))
    return checks


def _cache_key(tree: str, checks: List[Check]) -> str:
    scope = {"tree": tree, "checks": [[check.name, check.command] for check in checks]}
    return hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()


def _run(root: Path, prelude: str, check: Check, log: Path, live: list) -> Result:
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with log.open("w") as stream:
        stream.write(f"$ {check.command}\n")
        stream.flush()
        process = subprocess.Popen(
            ["bash", "-c", f"set -eo pipefail\n{prelude}\n{check.command}"],
            cwd=root, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        live.append(process)
        try:
            code = process.wait()
        finally:
            live.remove(process)
            # A check owns its process group: anything it left running goes with it.
            _kill_group(process)
    return Result(check, code, round(time.monotonic() - started, 1), log)


def _kill_group(process: subprocess.Popen) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)


def _excerpt(log: Path) -> str:
    lines = log.read_text(errors="replace").splitlines()[-EXCERPT_LINES:]
    return "\n".join(f"    {line}" for line in lines)


def verify(root: Path, config: dict, tests: List[str], base_ref: str) -> bool:
    """Run the checks the branch needs on HEAD; True when all pass. Prints one line per check."""
    dirty = dirty_paths(root)
    if dirty:
        raise VerifyError("commit or remove local changes first; verify checks a commit:\n  "
                          + "\n  ".join(dirty[:20]))
    head = _git(root, "rev-parse", "HEAD").strip()
    tree = _git(root, "rev-parse", "HEAD^{tree}").strip()
    if subprocess.run(["git", "rev-parse", "--verify", "-q", f"{base_ref}^{{commit}}"], cwd=root,
                      capture_output=True).returncode != 0:
        raise VerifyError(f"{base_ref} is not fetched; run work land, or fetch it first")
    merge_base, changed = branch_changes(root, base_ref)
    checks = plan(root, changed, tests, merge_base)
    key = _cache_key(tree, checks)
    marker = _git_dir(root) / "work" / "verified" / key
    if marker.exists():
        print(f"verify: tree {tree[:12]} already passed these {len(checks)} checks; nothing to run")
        return True

    prelude = config["verify"]["prelude"]
    logs = _git_dir(root) / "work" / "logs" / head[:12]
    print(f"verify: {len(checks)} checks for {head[:12]} against {base_ref}")
    live: list = []
    results: List[Result] = []
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
        futures = [pool.submit(_run, root, prelude, check, logs / f"{check.name}.log", live)
                   for check in checks]
        try:
            for future in as_completed(futures):
                result = future.result()
                results.append(result)
                verdict = "pass" if result.exit_code == 0 else f"FAIL (exit {result.exit_code})"
                print(f"  {result.check.name}: {verdict} in {result.seconds}s  ({result.log})", flush=True)
        except BaseException:
            # Interrupted or failed: stop what the checks started, before the pool waits on them.
            for process in list(live):
                _kill_group(process)
            raise

    failed = [result for result in results if result.exit_code != 0]
    for result in failed:
        print(f"\n--- {result.check.name}: {result.check.command}\n{_excerpt(result.log)}")
    if failed:
        return False
    if _git(root, "rev-parse", "HEAD").strip() != head or dirty_paths(root):
        raise VerifyError("the head or the worktree changed while checks ran; nothing was recorded")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({
        "tree": tree,
        "head": head,
        "checks": [check.name for check in checks],
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }, indent=2) + "\n")
    return True
