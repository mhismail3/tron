#!/usr/bin/env python3
"""Checks source declarations and audits Tron-home metadata without mutations."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "packages/gateway/src/foundation/tron-home-layout.json"
FIELDS = {"owner", "writer", "life", "rebuild", "backup", "secret", "retention", "view"}
LIVES = {"durable", "cache", "scratch", "log", "lock"}
VIEWS = {"system", "config", "knowledge"}
SECRETS = {None, "private", "credential"}
EXTERNAL_OWNERS = ("pi-sdk", "pi-subagents", "extension")


class LayoutError(Exception):
    pass


def load(root: Path = ROOT) -> dict:
    try:
        return json.loads((root / REGISTRY).read_text())
    except (OSError, ValueError) as error:
        raise LayoutError(f"{REGISTRY}: {error}") from error


def matches(pattern: str, relative: str) -> bool:
    wanted, actual = pattern.split("/"), relative.split("/")
    return len(wanted) == len(actual) and all(
        fnmatch.fnmatchcase(part, rule) for rule, part in zip(wanted, actual)
    )


def registration(paths: dict, relative: str) -> tuple[str | None, str]:
    parts = relative.split("/")
    for length in range(len(parts), 0, -1):
        prefix = "/".join(parts[:length])
        candidates = sorted(paths, key=lambda key: (key != prefix, -len(key.replace("*", "")), key))
        for key in candidates:
            if matches(key, prefix):
                if length < len(parts) and not paths[key].get("subtree"):
                    return None, "unknown"
                return key, "delegated" if length < len(parts) else "registered" if key == relative else "pattern"
    return None, "unknown"


def registered(paths: dict, relative: str) -> bool:
    return registration(paths, relative)[0] is not None


def modules(root: Path) -> set[str]:
    """Module ids from the one ownership authority."""
    sys.path.insert(0, str(root / "tools/ownership"))
    import ownership  # noqa: E402
    return set(ownership.check()[0]["modules"])


def validate(registry: dict, root: Path) -> list[str]:
    problems, paths, known = [], registry.get("paths", {}), modules(root)
    for key, entry in paths.items():
        missing = FIELDS - entry.keys()
        if missing:
            problems.append(f"{key}: missing {', '.join(sorted(missing))}")
            continue
        if entry["life"] not in LIVES or entry["view"] not in VIEWS or entry["secret"] not in SECRETS:
            problems.append(f"{key}: life, view or secret is not one of the declared values")
        if not isinstance(entry["backup"], bool):
            problems.append(f"{key}: backup must be true or false")
        for flag in ("container", "subtree"):
            if flag in entry and not isinstance(entry[flag], bool):
                problems.append(f"{key}: {flag} must be true or false")
        owner = entry["owner"]
        if not owner.startswith(EXTERNAL_OWNERS) and owner not in known:
            problems.append(f"{key}: owner {owner} is not a module (scripts/tron ownership --modules)")
        parent = key.rsplit("/", 1)[0]
        if "/" in key and parent not in paths:
            problems.append(f"{key}: parent {parent} is not registered")
    return problems


LITERALS = [
    re.compile(r"\.tron/([\w.-]+)(?:/([\w.*-]+))?"),
    re.compile(r"""["']\.tron["']\s*[,/]\s*["']([\w.-]+)["'](?:\s*[,/]\s*["']([\w.*-]+)["'])?"""),
    re.compile(r'\b\w*[hH]ome\b[^\n]*?appendingPathComponent\(\s*"([\w.-]+)(?:/([\w.*-]+))?"'),
    re.compile(r"""\b(?:join|resolve)\(\s*[\w.]*(?:tronHome|tron_home|TRON_HOME|\bhome)\b[^,()]*,\s*["']([\w.-]+)["'](?:\s*,\s*["']([\w.*-]+)["'])?"""),
]
TRON_RECEIVER = re.compile(r"tronHome|tron_home|TRON_HOME|TronHome")
GATEWAY_JOIN = LITERALS[3]
SOURCE_ROOTS = ("packages/gateway/src", "packages/gateway/scripts", "packages/mac-app/Sources", "packages/mac-app/scripts", "scripts", "tools")
SOURCE_SUFFIXES = {".ts", ".mjs", ".js", ".py", ".swift", ".c", ".sh"}
TEST_NAME = re.compile(r"((^|/)test[-_][^/]*$|[.-]test\.|\.(integration|e2e|lock)\.|Tests?/|/tests/)")
EXEMPT = {"packages/gateway/src/foundation/tron-home-layout.ts", "tools/home-layout/home_layout.py"}


def tracked(root: Path) -> list[str]:
    output = subprocess.run(["git", "ls-files", "--", *SOURCE_ROOTS], cwd=root, check=True, capture_output=True, text=True).stdout
    return [path for path in output.splitlines()
            if not TEST_NAME.search(path) and path not in EXEMPT
            and (Path(path).suffix in SOURCE_SUFFIXES or (not Path(path).suffix and (root / path).is_file()))]


def check(root: Path = ROOT) -> list[str]:
    registry = load(root)
    problems = validate(registry, root)
    paths = registry["paths"]
    roots = {key for key in paths if "/" not in key}
    for path in tracked(root):
        try:
            text = (root / path).read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            joined = GATEWAY_JOIN.search(line)
            if path.startswith("packages/gateway/src/") and joined and joined.group(1) in roots:
                problems.append(f"{path}:{number}: resolve Tron-home paths with tronHomePath(), not a literal join")
                continue
            for index, pattern in enumerate(LITERALS):
                for match in pattern.finditer(line):
                    segments = [segment for segment in match.groups() if segment and not re.search(r"[*$]|^\.tron", segment)]
                    relative = "/".join(segments)
                    if index >= 2 and match.group(1) not in roots and not TRON_RECEIVER.search(match.group(0)):
                        continue
                    if relative and not registered(paths, relative):
                        problems.append(f"{path}:{number}: {relative} is not in {REGISTRY}")
    return problems


def audit_paths(registry: dict) -> dict:
    if not isinstance(registry, dict) or type(registry.get("version")) is not int or registry["version"] != 1:
        raise LayoutError("invalid_registry")
    paths = registry.get("paths")
    if not isinstance(paths, dict):
        raise LayoutError("invalid_registry")
    for key, entry in paths.items():
        if not isinstance(key, str) or any(part in ("", ".", "..") for part in key.split("/")):
            raise LayoutError("invalid_registry")
        if not isinstance(entry, dict) or FIELDS - entry.keys():
            raise LayoutError("invalid_registry")
        if not all(isinstance(entry[field], str) and entry[field] for field in ("owner", "writer", "life", "rebuild", "view")):
            raise LayoutError("invalid_registry")
        if entry["life"] not in LIVES or entry["view"] not in VIEWS:
            raise LayoutError("invalid_registry")
        if entry["secret"] is not None and (not isinstance(entry["secret"], str) or entry["secret"] not in SECRETS):
            raise LayoutError("invalid_registry")
        if not isinstance(entry["backup"], bool) or entry["retention"] is not None and not isinstance(entry["retention"], str):
            raise LayoutError("invalid_registry")
        if any(flag in entry and not isinstance(entry[flag], bool) for flag in ("container", "subtree")):
            raise LayoutError("invalid_registry")
        if "/" in key and key.rsplit("/", 1)[0] not in paths:
            raise LayoutError("invalid_registry")
    return paths


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def metadata(info: os.stat_result) -> dict:
    kind = "directory" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "symlink" if stat.S_ISLNK(info.st_mode) else "special"
    return {"type": kind, "device": info.st_dev, "inode": info.st_ino,
            "mode": oct(stat.S_IMODE(info.st_mode)), "uid": info.st_uid, "gid": info.st_gid,
            "bytes": info.st_size, "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}


def open_home(home: str) -> int:
    fd = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in Path(home).parts[1:]:
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def audit(home: str, max_entries: int, root: Path = ROOT) -> tuple[int, dict]:
    report = {"home": os.path.abspath(home), "source": {}, "root": None,
              "entries": [], "findings": [], "errors": [], "truncated": False, "complete": False}

    def error(path: str, reason: str, failure: OSError | None = None) -> None:
        report["errors"].append({"path": path, "reason": reason, "errno": failure.errno if failure else None})

    def scan(fd: int, relative: str, before: os.stat_result) -> None:
        try:
            with os.scandir(fd) as children:
                for child in children:
                    if len(report["entries"]) >= max_entries:
                        report["truncated"] = True
                        break
                    path = f"{relative}/{child.name}" if relative else child.name
                    try:
                        observed = os.stat(child.name, dir_fd=fd, follow_symlinks=False)
                        key, classification = registration(paths, path)
                        contract = paths[key] if key else {}
                        row = {"path": path, **metadata(observed), "classification": classification,
                               "registration": key, "contract": contract, "opaque": False}
                        report["entries"].append(row)
                        reasons = []
                        if key is None:
                            reasons.append("unknown")
                        if row["type"] in ("symlink", "special"):
                            reasons.append("unsafe_type")
                        elif row["type"] != "directory" and (contract.get("container") or contract.get("subtree")):
                            reasons.append("expected_directory")
                        if reasons:
                            report["findings"].append({"path": path, "reasons": reasons})
                        if row["type"] != "directory":
                            continue
                        explicit_children = any(
                            candidate.count("/") > path.count("/")
                            and matches("/".join(candidate.split("/")[:len(path.split("/"))]), path)
                            for candidate in paths
                        )
                        row["opaque"] = key is None or bool(contract.get("subtree") and not explicit_children)
                        if row["opaque"]:
                            continue
                        opened = os.open(child.name, DIRECTORY_FLAGS, dir_fd=fd)
                        try:
                            current = os.fstat(opened)
                            if metadata(current) != metadata(observed):
                                error(path, "directory_changed_before_open")
                            else:
                                scan(opened, path, current)
                            if metadata(os.stat(child.name, dir_fd=fd, follow_symlinks=False)) != metadata(observed):
                                error(path, "directory_replaced_or_changed")
                        finally:
                            os.close(opened)
                    except OSError as failure:
                        error(path, "entry_unavailable", failure)
                    if report["truncated"]:
                        break
            if metadata(os.fstat(fd)) != metadata(before):
                error(relative or ".", "directory_changed_during_scan")
        except OSError as failure:
            error(relative or ".", "enumeration_failed", failure)

    try:
        registry = load(root)
        paths = audit_paths(registry)
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True)
        report["source"] = {"revision": revision.stdout.strip() if revision.returncode == 0 else None,
                            "manifest": REGISTRY, "manifest_version": registry["version"],
                            "manifest_sha256": hashlib.sha256((root / REGISTRY).read_bytes()).hexdigest(),
                            "tool_sha256": hashlib.sha256((root / "tools/home-layout/home_layout.py").read_bytes()).hexdigest()}
        fd = open_home(report["home"])
        try:
            before = os.fstat(fd)
            report["root"] = metadata(before)
            scan(fd, "", before)
            reopened = open_home(report["home"])
            try:
                if metadata(os.fstat(reopened)) != metadata(before):
                    error(".", "root_replaced_or_changed")
            finally:
                os.close(reopened)
        finally:
            os.close(fd)
    except LayoutError as failure:
        error(REGISTRY, "invalid_registry" if str(failure) == "invalid_registry" else "registry_unavailable")
    except (OSError, KeyError, TypeError, ValueError) as failure:
        error(".", "audit_failed", failure if isinstance(failure, OSError) else None)
    report["entries"].sort(key=lambda row: row["path"])
    report["findings"].sort(key=lambda row: row["path"])
    report["complete"] = not report["errors"] and not report["truncated"]
    return (2 if not report["complete"] else 1 if report["findings"] else 0), report


def positive(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron home-layout", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="registry is valid and tracked source names only registered Tron-home paths")
    audit_parser = commands.add_parser("audit", help="read-only, no-follow ownership-boundary metadata scan")
    audit_parser.add_argument("--home", required=True, help="installation root; no default or implicit other-home access")
    audit_parser.add_argument("--json", action="store_true", required=True, help="emit metadata report to stdout")
    audit_parser.add_argument("--max-entries", type=positive, default=10000, help="scan budget; exhaustion exits 2 (default: 10000)")
    args = parser.parse_args(argv)
    if args.command == "audit":
        code, report = audit(args.home, args.max_entries)
        print(json.dumps(report, indent=2))
        return code
    try:
        problems = check()
    except LayoutError as error:
        print(f"home-layout: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print(problem)
    print(f"home-layout check: {len(problems)} problem(s), {len(load()['paths'])} registered paths")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
