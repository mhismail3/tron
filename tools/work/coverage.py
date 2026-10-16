"""No-skip Gateway V8 coverage observations (#1110).

These profiles report modules observed in one isolated Vitest worker, not a
complete dependency set. They are diagnostic lower bounds only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional
from urllib.parse import unquote, urlsplit


GLOBAL_INPUTS = (
    ".node-version",
    "config/GatewayProtocol.json",
    "packages/gateway/package.json",
    "packages/gateway/package-lock.json",
    "packages/gateway/vitest*.config.ts",
    "packages/gateway/test-support/**",
    "packages/gateway/test-fixtures/**",
    "packages/gateway/src/**/fixtures/**",
)
SOURCE_FILE = re.compile(r"^packages/gateway/src/.+\.(?:ts|tsx|mts|mjs|js)$")


class CoverageError(RuntimeError):
    pass


def _git(root: Path, *args: str) -> str:
    done = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if done.returncode:
        raise CoverageError(f"git {' '.join(args[:2])} failed: {done.stderr.strip()}")
    return done.stdout


def _git_dir(root: Path) -> Path:
    return Path(_git(root, "rev-parse", "--path-format=absolute", "--git-dir").strip())


def _tree(root: Path) -> str:
    # Match gate's content tree, including tracked edits and untracked test fixtures,
    # without touching the real index.
    import gate
    return gate.workspace_tree(root)


def _global_path(path: str) -> bool:
    from fnmatch import fnmatchcase
    return any(fnmatchcase(path, pattern) for pattern in GLOBAL_INPUTS)


def _record_dir(root: Path, tree: str) -> Path:
    return _git_dir(root) / "work" / "gate" / "coverage-observations" / tree


def _write_record(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(record, sort_keys=True) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _record_name(test: str) -> str:
    return hashlib.sha256(test.encode()).hexdigest() + ".json"


def _source_modules(profile_dir: Path, root: Path) -> tuple[List[str], int]:
    prefix = (root / "packages/gateway/src").resolve()
    modules: set[str] = set()
    profiles = 0
    for path in profile_dir.glob("coverage-*.json"):
        profiles += 1
        try:
            document = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(document, dict) or not isinstance(document.get("result"), list):
            continue
        for script in document["result"]:
            if not isinstance(script, dict) or not isinstance(script.get("url"), str):
                continue
            try:
                parts = urlsplit(script["url"])
            except ValueError:
                continue
            if parts.scheme != "file":
                continue
            candidate = Path(unquote(parts.path)).resolve()
            try:
                relative = candidate.relative_to(prefix)
            except ValueError:
                continue
            repo_path = (Path("packages/gateway/src") / relative).as_posix()
            if SOURCE_FILE.match(repo_path):
                modules.add(repo_path)
    return sorted(modules), profiles


def observe(root: Path, tests: List[str]) -> int:
    root = root.resolve()
    if not tests:
        raise CoverageError("coverage observe requires at least one --test")
    gateway = root / "packages/gateway"
    if not (gateway / "node_modules/vitest/vitest.mjs").is_file():
        raise CoverageError("Gateway Vitest dependencies are unavailable; no install is attempted")
    node_resolver = root / "scripts/tron-node"
    if not node_resolver.is_file():
        raise CoverageError("scripts/tron-node is required")
    tree = _tree(root)
    saved = _record_dir(root, tree)
    saved.mkdir(parents=True, exist_ok=True)
    node = subprocess.run([str(node_resolver)], cwd=root, capture_output=True, text=True)
    if node.returncode:
        raise CoverageError("could not resolve pinned Node: " + node.stderr.strip())
    node_path = node.stdout.strip()
    exit_code = 0
    for test in tests:
        normalized = Path(test).as_posix()
        record = {
            "schema": 1,
            "tree": tree,
            "head": _git(root, "rev-parse", "HEAD").strip(),
            "test": normalized,
            "status": "failed",
            "selectionEligible": False,
            "fallbackReasons": ["child-process evidence is unproven", "filesystem resource reads are unobserved"],
            "sourceModules": [],
            "profileCount": 0,
        }
        test_path = (root / normalized).resolve()
        try:
            test_path.relative_to((gateway / "src").resolve())
        except ValueError:
            record["fallbackReasons"].append("test is outside the default Gateway source tree")
            _write_record(saved / _record_name(normalized), record)
            print(json.dumps(record, sort_keys=True))
            exit_code = 1
            continue
        if not test_path.is_file() or not re.search(r"\.(?:test|spec)\.ts$", test_path.name):
            record["fallbackReasons"].append("test is missing or is not a TypeScript test file")
            _write_record(saved / _record_name(normalized), record)
            print(json.dumps(record, sort_keys=True))
            exit_code = 1
            continue
        with tempfile.TemporaryDirectory(prefix="tron-gateway-coverage-") as raw:
            command = [node_path, str(gateway / "node_modules/vitest/vitest.mjs"), "run",
                       "--config", "vitest.coverage-observer.config.ts", normalized.removeprefix("packages/gateway/")]
            env = {**os.environ, "NODE_V8_COVERAGE": raw}
            outcome = subprocess.run(command, cwd=gateway, env=env, check=False)
            modules, profile_count = _source_modules(Path(raw), root)
            record["sourceModules"] = modules
            record["profileCount"] = profile_count
            record["status"] = "observed" if outcome.returncode == 0 and normalized in modules else "failed"
            if normalized not in modules:
                record["fallbackReasons"].append("test module was not present in flushed V8 profiles")
            if outcome.returncode:
                record["fallbackReasons"].append(f"Vitest exited {outcome.returncode}")
            current_tree = _tree(root)
            if current_tree != tree:
                record["status"] = "stale"
                record["fallbackReasons"].append("worktree changed during the observation")
            _write_record(saved / _record_name(normalized), record)
            print(json.dumps(record, sort_keys=True))
            if record["status"] != "observed":
                exit_code = 1
    return exit_code


def report(root: Path, tests: List[str], base_tree: Optional[str], changed: List[str], as_json: bool) -> int:
    root = root.resolve()
    current_tree = _tree(root)
    if base_tree:
        if not re.fullmatch(r"[0-9a-f]{40,64}", base_tree):
            raise CoverageError("--base-tree must be a Git tree or commit object id")
        base_tree = _git(root, "rev-parse", f"{base_tree}^{{tree}}").strip()
        paths = changed or [p for p in _git(root, "diff", "--name-only", "-z", base_tree, current_tree).split("\0") if p]
    else:
        paths = changed
    if not tests:
        store = _record_dir(root, current_tree)
        tests = []
        if store.is_dir():
            for path in sorted(store.glob("*.json")):
                try:
                    record = json.loads(path.read_text())
                    tests.append(record["test"] if isinstance(record, dict) and isinstance(record.get("test"), str) else path.stem)
                except (OSError, json.JSONDecodeError):
                    tests.append(path.stem)
    global_changes = [path for path in paths if _global_path(path)]
    source_changes = [path for path in paths if SOURCE_FILE.match(path) and not path.endswith((".test.ts", ".spec.ts"))]
    unknown_changes = [path for path in paths if path not in global_changes and path not in source_changes]
    observations = []
    lower_bound_hits = {path: 0 for path in source_changes}
    counts = {"observed": 0, "missing": 0, "stale": 0, "failed": 0, "corrupt": 0}
    record_dir = _record_dir(root, base_tree or current_tree)
    for test in tests:
        path = record_dir / _record_name(test)
        record: Optional[dict] = None
        state = "missing"
        if path.exists():
            try:
                candidate = json.loads(path.read_text())
                if not isinstance(candidate, dict):
                    raise ValueError("record must be an object")
                status = candidate.get("status")
                if (type(candidate.get("schema")) is not int or candidate["schema"] != 1
                        or candidate.get("test") != test
                        or not isinstance(candidate.get("tree"), str)
                        or not re.fullmatch(r"[0-9a-f]{40,64}", candidate["tree"])
                        or not isinstance(status, str)
                        or status not in {"observed", "failed", "stale"}
                        or not isinstance(candidate.get("sourceModules"), list)
                        or any(not isinstance(module, str) or not SOURCE_FILE.match(module)
                               for module in candidate["sourceModules"])
                        or not isinstance(candidate.get("fallbackReasons"), list)
                        or any(not isinstance(reason, str) for reason in candidate["fallbackReasons"])
                        or type(candidate.get("profileCount")) is not int
                        or candidate["profileCount"] < 0):
                    raise ValueError("record shape or identity is invalid")
                record = candidate
                state = record["status"]
                if record["tree"] != (base_tree or current_tree):
                    state = "stale"
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                state = "corrupt"
        counts[state] += 1
        modules = set(record.get("sourceModules", [])) if record and state == "observed" else set()
        for changed_path in source_changes:
            if changed_path in modules:
                lower_bound_hits[changed_path] += 1
        observations.append({"test": test, "evidence": state, "observedSourceModules": len(modules),
                             "fallback": True,
                             "fallbackReasons": (record or {}).get("fallbackReasons", [f"{state} evidence"])
                             + (["declared global input changed"] if global_changes else [])
                             + (["unmapped changed path"] if unknown_changes else [])})
    result = {
        "tree": current_tree,
        "evidenceTree": base_tree or current_tree,
        "testsRequested": len(tests),
        "evidenceCounts": counts,
        "changedPaths": paths,
        "globalInputChanges": global_changes,
        "unmappedChanges": unknown_changes,
        "observedLoadedModuleFanoutLowerBound": lower_bound_hits,
        "observations": observations,
        "selectionEnabled": False,
        "fallbackTests": len(tests),
        "fallbackShare": 1.0 if tests else 0.0,
        "note": "Loaded-module footprint is a diagnostic lower bound; child coverage and filesystem reads are not complete evidence. No checks are skipped.",
    }
    print(json.dumps(result, indent=2 if not as_json else None, sort_keys=True))
    return 0
