#!/usr/bin/env python3
"""Checks the Tron-home registry, audits ownership and migrates retired paths offline."""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "packages/gateway/src/foundation/tron-home-layout.json"
VERSION = 2
CLASSES = {"keep", "rebuild", "scratch", "log"}
PRUNED_CLASSES = {"rebuild", "scratch"}
REGISTRY_FIELDS = {"version", "paths", "retired"}
ENTRY_FIELDS = {"owner", "class", "backup", "credential", "container", "subtree", "prune", "type"}
PRUNE_BOUNDS = {"when": str, "maxAge": str, "maxEntries": int, "maxBytes": int, "keepNewest": int}
PRUNE_FIELDS = {"by": str, **PRUNE_BOUNDS}
AGE = re.compile(r"[1-9]\d*[mhd]")
EXTERNAL_OWNERS = re.compile(r"(?:pi-sdk|pi-subagents|extension \S+)")
RUNTIME_LOCK = "agent/.tron-gateway-runtime.lock.lock"
RUNTIME_LOCK_STALE_SECONDS = 60


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


def lineage(paths: dict, key: str):
    while True:
        if key in paths:
            yield paths[key]
        if "/" not in key:
            return
        key = key.rsplit("/", 1)[0]


def class_of(paths: dict, key: str) -> str | None:
    return next((entry["class"] for entry in lineage(paths, key) if "class" in entry), None)


def backed_up(paths: dict, key: str) -> bool:
    for entry in lineage(paths, key):
        if "backup" in entry:
            return entry["backup"]
        if "class" in entry:
            return entry["class"] == "keep"
    return True


def backup_decision(paths: dict, relative: str, directory: bool) -> str:
    key, classification = registration(paths, relative)
    if key is None:
        return "all"
    own = backed_up(paths, key)
    if directory and classification != "delegated":
        depth = relative.count("/") + 1
        below = (candidate for candidate in paths
                 if candidate.count("/") >= depth and matches("/".join(candidate.split("/")[:depth]), relative))
        if any(backed_up(paths, candidate) != own for candidate in below) or not own and not paths[key].get("subtree"):
            return "mixed"
    return "all" if own else "none"


def backup_walk(paths: dict, home: Path):
    def visit(directory: Path, prefix: str):
        with os.scandir(directory) as children:
            ordered = sorted(children, key=lambda child: child.name)
        for child in ordered:
            relative = prefix + child.name
            decision = backup_decision(paths, relative, child.is_dir(follow_symlinks=False))
            if decision == "none":
                continue
            yield relative, decision
            if decision == "mixed":
                yield from visit(Path(child.path), relative + "/")
    yield from visit(Path(home), "")


def relative_parts(value: object) -> bool:
    return isinstance(value, str) and bool(value) and not any(part in ("", ".", "..") for part in value.split("/"))


def location(value: object) -> bool:
    return isinstance(value, str) and relative_parts(value[2:] if value.startswith("~/") else value)


def prune_problem(prune: object) -> str | None:
    if not isinstance(prune, dict) or prune.keys() - PRUNE_FIELDS.keys():
        return "prune must be an object of by, when, maxAge, maxEntries, maxBytes or keepNewest"
    if not prune.keys() & PRUNE_BOUNDS.keys():
        return "prune needs a bound: when, maxAge, maxEntries, maxBytes or keepNewest"
    for field, value in prune.items():
        expected = PRUNE_FIELDS[field]
        if type(value) is not expected or expected is int and value <= 0 or expected is str and not value:
            return f"prune.{field} must be a {'positive integer' if expected is int else 'non-empty string'}"
    if "maxAge" in prune and not AGE.fullmatch(prune["maxAge"]):
        return "prune.maxAge is a count and a unit, such as 30m, 24h or 14d"
    return None


def shape(registry: object) -> list[str]:
    if not isinstance(registry, dict) or type(registry.get("version")) is not int or registry["version"] != VERSION:
        return [f"registry version must be {VERSION}"]
    if registry.keys() - REGISTRY_FIELDS:
        return [f"unknown registry field(s) {', '.join(sorted(registry.keys() - REGISTRY_FIELDS))}"]
    paths, retired = registry.get("paths"), registry.get("retired", [])
    if not isinstance(paths, dict) or not isinstance(retired, list):
        return ["paths must be an object and retired a list"]
    problems = []
    for key, entry in paths.items():
        if not relative_parts(key):
            problems.append(f"{key}: not a home-relative path")
            continue
        if not isinstance(entry, dict):
            problems.append(f"{key}: entry must be an object")
            continue
        unknown = entry.keys() - ENTRY_FIELDS
        if unknown:
            problems.append(f"{key}: unknown field(s) {', '.join(sorted(unknown))}")
        if not isinstance(entry.get("owner"), str) or not entry["owner"]:
            problems.append(f"{key}: owner must name a module")
        if "class" in entry and (not isinstance(entry["class"], str) or entry["class"] not in CLASSES):
            problems.append(f"{key}: class must be one of {', '.join(sorted(CLASSES))}")
        if "/" not in key and "class" not in entry:
            problems.append(f"{key}: a top-level entry states its class")
        for flag in ("backup", "container", "subtree"):
            if flag in entry and not isinstance(entry[flag], bool):
                problems.append(f"{key}: {flag} must be true or false")
        if "type" in entry and entry["type"] != "fifo":
            problems.append(f"{key}: type must be fifo or absent")
        if "credential" in entry and entry["credential"] is not True:
            problems.append(f"{key}: credential is true or absent")
        if "/" in key and key.rsplit("/", 1)[0] not in paths:
            problems.append(f"{key}: parent {key.rsplit('/', 1)[0]} is not registered")
        if "prune" in entry:
            problem = prune_problem(entry["prune"])
            if problem:
                problems.append(f"{key}: {problem}")
    if problems:
        return problems
    for key, entry in paths.items():
        if entry.get("subtree") and "prune" not in entry and class_of(paths, key) in PRUNED_CLASSES:
            problems.append(f"{key}: a {class_of(paths, key)} subtree states its prune rule")
    seen = set()
    for move in retired:
        if not isinstance(move, dict) or move.keys() != {"from", "to"} or not location(move["from"]) or not location(move["to"]):
            problems.append(f"retired: {json.dumps(move)} must be {{from, to}} with home-relative or ~/ paths")
        elif move["from"] == move["to"] or move["to"].startswith(move["from"] + "/") or {("from", move["from"]), ("to", move["to"])} & seen:
            problems.append(f"retired: {move['from']} moves once, to a place nothing else moves to")
        else:
            seen |= {("from", move["from"]), ("to", move["to"])}
    return problems


def modules(root: Path) -> set[str]:
    sys.path.insert(0, str(root / "tools/ownership"))
    import ownership  # noqa: E402
    return set(ownership.check()[0]["modules"])


def validate(registry: dict, root: Path) -> list[str]:
    problems = shape(registry)
    if problems:
        return problems
    known = modules(root)
    for key, entry in registry["paths"].items():
        if not EXTERNAL_OWNERS.fullmatch(entry["owner"]) and entry["owner"] not in known:
            problems.append(f"{key}: owner {entry['owner']} is not a module (scripts/tron ownership --modules)")
    return problems


HOME_NAME = r"\.tron(?:-dev)?"
LITERALS = [
    re.compile(HOME_NAME + r"/([\w.-]+)(?:/([\w.*-]+))?"),
    re.compile(r"""["']""" + HOME_NAME + r"""["']\s*[,/]\s*["']([\w.-]+)["'](?:\s*[,/]\s*["']([\w.*-]+)["'])?"""),
    re.compile(r"""\b(?:join|resolve)\(\s*(?:(?:path\.)?(?:resolve|realpathSync|normalize)\(\s*)?[\w.]*(?:tronHome|tron_home|TRON_HOME|\bhome)\b[^,()]*\)?\s*,\s*["']([\w.-]+)["'](?:\s*,\s*["']([\w.*-]+)["'])?"""),
]
GATEWAY_JOIN = LITERALS[2]
SWIFT_CHAIN = re.compile(r'\b\w*[hH]ome\b[^\n]*?((?:\s*\.?appendingPathComponent\(\s*"[^"\n]*"[^()\n]*\))+)')
SWIFT_COMPONENT = re.compile(r'appendingPathComponent\(\s*"([^"\n]*)"')
SHELL_ASSIGNMENT = re.compile(r"""^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_]\w*)=["']?(\S*?)["']?\s*$""")
SHELL_HOME_VALUE = re.compile(HOME_NAME + r"((?:/[\w.-]+)*)\}?((?:/[\w.-]+)*)/?$")
SHELL_VARIABLE_VALUE = re.compile(r"\$\{?([A-Za-z_]\w*)\}?/([\w./-]+)$")
SHELL_USE = re.compile(r"\$\{?([A-Za-z_]\w*)\}?/([\w.-]+)(?:/([\w.-]+))?")
DYNAMIC = re.compile(r"[*$]|\\\(")
SKIPPED_SEGMENT = re.compile(r"[*$]|^\.tron")
TRON_RECEIVER = re.compile(r"tronHome|tron_home|TRON_HOME|TronHome")
SOURCE_ROOTS = ("packages/gateway/src", "packages/gateway/scripts", "packages/mac-app/Sources", "packages/mac-app/scripts", "scripts", "tools")
SOURCE_SUFFIXES = {".ts", ".mjs", ".js", ".py", ".swift", ".c", ".sh"}
TEST_NAME = re.compile(r"((^|/)test[-_][^/]*$|[.-]test\.|\.(integration|e2e|lock)\.|Tests?/|/tests/)")
EXEMPT = {"packages/gateway/src/foundation/tron-home-layout.ts", "tools/home-layout/home_layout.py"}


def tracked(root: Path) -> list[str]:
    output = subprocess.run(["git", "ls-files", "--", *SOURCE_ROOTS], cwd=root, check=True, capture_output=True, text=True).stdout
    return [path for path in output.splitlines()
            if not TEST_NAME.search(path) and path not in EXEMPT
            and (Path(path).suffix in SOURCE_SUFFIXES or (not Path(path).suffix and (root / path).is_file()))]


def literal_paths(path: str, text: str, roots: set[str]):
    bound: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        joined = GATEWAY_JOIN.search(line)
        if path.startswith("packages/gateway/src/") and joined and joined.group(1) in roots:
            yield number, None
            continue
        for index, pattern in enumerate(LITERALS):
            for match in pattern.finditer(line):
                if index == 2 and match.group(1) not in roots and not TRON_RECEIVER.search(match.group(0)):
                    continue
                yield number, "/".join(segment for segment in match.groups() if segment and not SKIPPED_SEGMENT.search(segment))
        assignment = SHELL_ASSIGNMENT.match(line)
        value = assignment.group(2) if assignment else ""
        home_value, variable_value = SHELL_HOME_VALUE.search(value), SHELL_VARIABLE_VALUE.fullmatch(value)
        if home_value:
            bound[assignment.group(1)] = (home_value.group(1) + home_value.group(2)).strip("/")
            if home_value.group(2):
                yield number, bound[assignment.group(1)]
        elif variable_value and variable_value.group(1) in bound:
            bound[assignment.group(1)] = f"{bound[variable_value.group(1)]}/{variable_value.group(2)}".strip("/")
        elif assignment:
            bound.pop(assignment.group(1), None)
        for use in SHELL_USE.finditer(line):
            if use.group(1) not in bound:
                continue
            segments = [segment for segment in use.groups()[1:] if segment]
            if line[use.end():use.end() + 1] in ("*", "$", "{"):
                segments.pop()
            if segments:
                yield number, "/".join([bound[use.group(1)], *segments]).strip("/").rstrip(".")
    for chain in SWIFT_CHAIN.finditer(text):
        if "deletingLastPathComponent" in chain.group(0):
            continue
        components = []
        for component in SWIFT_COMPONENT.findall(chain.group(1)):
            if DYNAMIC.search(component):
                break
            components.append(component)
        if components and (components[0].split("/")[0] in roots or TRON_RECEIVER.search(chain.group(0))):
            yield text.count("\n", 0, chain.start()) + 1, "/".join(components)


def check(root: Path = ROOT) -> list[str]:
    registry = load(root)
    problems = validate(registry, root)
    if shape(registry):
        return problems
    paths = registry["paths"]
    roots = {key for key in paths if "/" not in key}
    for path in tracked(root):
        try:
            text = (root / path).read_text()
        except (OSError, UnicodeDecodeError):
            continue
        for number, relative in sorted(set(literal_paths(path, text, roots)), key=lambda item: (item[0], item[1] or "")):
            if relative is None:
                problems.append(f"{path}:{number}: resolve Tron-home paths with tronHomePath(), not a literal join")
            elif relative and not registered(paths, relative):
                problems.append(f"{path}:{number}: {relative} is not in {REGISTRY}")
    return problems


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


def source_identity(registry: dict, root: Path) -> dict:
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True)
    return {"revision": revision.stdout.strip() if revision.returncode == 0 else None,
            "manifest": REGISTRY, "manifest_version": registry["version"],
            "manifest_sha256": hashlib.sha256((root / REGISTRY).read_bytes()).hexdigest(),
            "tool_sha256": hashlib.sha256((root / "tools/home-layout/home_layout.py").read_bytes()).hexdigest()}


def audit(home: str, max_entries: int, root: Path = ROOT, maintenance: str | None = None) -> tuple[int, dict]:
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
                               "registration": key, "contract": contract,
                               "class": class_of(paths, key) if key else None,
                               "backup": backed_up(paths, key) if key else None, "opaque": False}
                        report["entries"].append(row)
                        reasons = []
                        if key is None:
                            reasons.append("unknown")
                        if contract.get("type") == "fifo":
                            if not stat.S_ISFIFO(observed.st_mode):
                                reasons.append("expected_fifo")
                        elif row["type"] in ("symlink", "special"):
                            reasons.append("unsafe_type")
                        elif classification != "delegated" and row["type"] != "directory" and (contract.get("container") or contract.get("subtree")):
                            reasons.append("expected_directory")
                        if contract.get("credential") and classification != "delegated" and stat.S_IMODE(observed.st_mode) & 0o077:
                            reasons.append("credential_mode")
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
        if shape(registry):
            raise LayoutError("invalid_registry")
        paths = registry["paths"]
        report["source"] = source_identity(registry, root)
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
    if maintenance is not None:
        try:
            report["findings"].extend(maintenance_index(maintenance))
        except (OSError, ValueError) as failure:
            error("maintenance", "index_unavailable", failure if isinstance(failure, OSError) else None)
    report["entries"].sort(key=lambda row: row["path"])
    report["findings"].sort(key=lambda row: row["path"])
    report["complete"] = not report["errors"] and not report["truncated"]
    return (2 if not report["complete"] else 1 if report["findings"] else 0), report


def maintenance_index(directory: str) -> list[dict]:
    fd = open_home(os.path.abspath(directory))
    try:
        rows = {}
        try:
            readme = os.open("README.md", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        except FileNotFoundError:
            readme = None
        if readme is not None:
            with os.fdopen(readme) as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
                    raise ValueError("unsafe_readme")
                columns = None
                for line in stream:
                    if not line.lstrip().startswith("|"):
                        columns = None
                        continue
                    cells = [cell.strip().strip("`") for cell in line.strip().strip("|").split("|")]
                    labels = [cell.lower() for cell in cells]
                    if "entry" in labels and "owner" in labels and any("rule" in cell for cell in labels):
                        columns = (labels.index("entry"), labels.index("owner"), next(i for i, cell in enumerate(labels) if "rule" in cell))
                    elif columns and len(cells) > max(columns):
                        name, owner, rule = (cells[index] for index in columns)
                        if name in rows:
                            rows[name] = False
                        else:
                            rows[name] = bool(owner.strip("- ") and rule.strip("- "))
        names = []
        with os.scandir(fd) as children:
            for child in children:
                if child.name == "README.md":
                    continue
                names.append(child.name)
                if child.name == "backups" and child.is_dir(follow_symlinks=False):
                    backup_fd = os.open(child.name, DIRECTORY_FLAGS, dir_fd=fd)
                    try:
                        with os.scandir(backup_fd) as backups:
                            names.extend("backups/" + backup.name for backup in backups)
                    finally:
                        os.close(backup_fd)
        return [{"path": "maintenance/" + name, "reasons": ["maintenance_index"]} for name in sorted(names) if not rows.get(name)]
    finally:
        os.close(fd)


def observed(path: str) -> os.stat_result | None:
    try:
        return os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):
        return None


def linked_component(path: str, stop: str) -> bool:
    parent = os.path.dirname(path)
    while len(parent) > len(stop):
        info = observed(parent)
        if info is not None and stat.S_ISLNK(info.st_mode):
            return True
        parent = os.path.dirname(parent)
    return False


def nearest_parent(path: str) -> os.stat_result:
    parent = os.path.dirname(path)
    while True:
        info = observed(parent)
        if info is not None:
            return info
        parent = os.path.dirname(parent)


def migration(home: str, root: Path = ROOT) -> dict:
    report = {"home": os.path.abspath(home), "user_home": os.path.abspath(os.path.expanduser("~")), "source": {},
              "state": None, "moves": [], "blockers": [], "errors": []}
    try:
        registry = load(root)
        if shape(registry):
            raise LayoutError("invalid_registry")
        report["source"] = source_identity(registry, root)
        os.close(open_home(report["home"]))
        lock = observed(os.path.join(report["home"], RUNTIME_LOCK))
        if lock is not None and time.time() - lock.st_mtime < RUNTIME_LOCK_STALE_SECONDS:
            report["blockers"].append("gateway_running")
        debug_lock = observed(os.path.join(report["user_home"], ".tron-dev", RUNTIME_LOCK))
        if debug_lock is not None and time.time() - debug_lock.st_mtime < RUNTIME_LOCK_STALE_SECONDS and report["home"] != os.path.join(report["user_home"], ".tron-dev"):
            report["blockers"].append("debug_gateway_running")
        for move in registry.get("retired", []):
            source, destination = (os.path.join(report["user_home"], value[2:]) if value.startswith("~/") else os.path.join(report["home"], value)
                                   for value in (move["from"], move["to"]))
            before, after = observed(source), observed(destination)
            row = {"from": move["from"], "to": move["to"], "source": source, "destination": destination,
                   "state": "conflict" if before and after else "pending" if before else "done" if after else "absent",
                   "identity": metadata(before or after) if before or after else None, "refusals": []}
            if row["state"] == "conflict":
                row["refusals"].append("destination_exists")
            if row["state"] == "pending":
                if row["identity"]["type"] not in ("file", "directory"):
                    row["refusals"].append("unsafe_type")
                if linked_component(source, "/") or linked_component(destination, "/"):
                    row["refusals"].append("symlink_component")
                parent = nearest_parent(destination)
                if not stat.S_ISDIR(parent.st_mode) and not stat.S_ISLNK(parent.st_mode):
                    row["refusals"].append("parent_not_directory")
                if parent.st_dev != before.st_dev:
                    row["refusals"].append("cross_volume")
            report["moves"].append(row)
        states = {row["state"] for row in report["moves"]}
        report["state"] = ("nothing_declared" if not report["moves"] else "conflict" if "conflict" in states
                           else "partly_applied" if {"pending", "done"} <= states else "not_started" if "pending" in states
                           else "applied" if "done" in states else "nothing_to_move")
    except LayoutError as failure:
        report["errors"].append({"path": REGISTRY, "reason": "invalid_registry" if str(failure) == "invalid_registry" else "registry_unavailable", "errno": None})
    except OSError as failure:
        report["errors"].append({"path": ".", "reason": "home_unavailable", "errno": failure.errno})
    return report


def migrate(home: str, status: bool, root: Path = ROOT) -> tuple[int, dict]:
    report = migration(home, root)
    if report["errors"]:
        return 2, report
    if status:
        summary = {key: report[key] for key in ("home", "source", "state", "blockers", "errors")}
        summary["moves"] = [{key: row[key] for key in ("from", "to", "state")} for row in report["moves"]]
        return (1 if report["state"] in ("not_started", "partly_applied", "conflict") else 0), summary
    try:
        journal_context(report)
    except (OSError, ValueError, KeyError, TypeError, LayoutError) as failure:
        report["blockers"].append(str(failure) if isinstance(failure, LayoutError) else "journal_unavailable")
    refused = report["blockers"] or any(row["refusals"] for row in report["moves"])
    return (1 if refused else 0), report


def private_directory(path: Path) -> None:
    missing = []
    parent = path
    while observed(str(parent)) is None:
        missing.append(parent)
        parent = parent.parent
    os.close(open_home(str(parent)))
    for directory in reversed(missing):
        directory.mkdir(mode=0o700)
    os.close(open_home(str(path)))


def write_journal(path: Path, journal: dict) -> None:
    temporary = path.with_suffix(".partial")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(journal, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = open_home(str(path.parent))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def rename_exclusive(source: str, destination: str) -> None:
    source_fd, destination_fd = open_home(os.path.dirname(source)), open_home(os.path.dirname(destination))
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if sys.platform == "darwin":
            result = libc.renameatx_np(source_fd, os.fsencode(os.path.basename(source)), destination_fd,
                                      os.fsencode(os.path.basename(destination)), 4)
        else:
            result = libc.renameat2(source_fd, os.fsencode(os.path.basename(source)), destination_fd,
                                    os.fsencode(os.path.basename(destination)), 1)
        if result:
            raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
        os.fsync(source_fd)
        os.fsync(destination_fd)
    finally:
        os.close(source_fd)
        os.close(destination_fd)


@contextlib.contextmanager
def runtime_lock(path: Path):
    private_directory(path.parent)
    path.mkdir(mode=0o700)
    fd = open_home(str(path))
    identity = os.fstat(fd)
    stop = threading.Event()
    errors = []

    def refresh():
        while not stop.wait(10):
            try:
                os.utime(fd, None)
            except OSError as failure:
                errors.append(failure)
                return

    def check():
        current = observed(str(path))
        if errors or current is None or (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
            raise LayoutError("runtime_lock_lost")

    heartbeat = threading.Thread(target=refresh, daemon=True)
    heartbeat.start()
    try:
        yield check
    finally:
        stop.set()
        heartbeat.join()
        os.close(fd)
        current = observed(str(path))
        if current is not None and (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
            path.rmdir()


def move_position(row: dict) -> str:
    before, after = observed(row["source"]), observed(row["destination"])
    current = before or after
    if (before is not None and after is not None or current is None
            or (current.st_dev, current.st_ino) != (row["identity"]["device"], row["identity"]["inode"])
            or linked_component(row["source"], "/") or linked_component(row["destination"], "/")):
        raise LayoutError("move_identity_changed")
    return "pending" if before is not None else "done"


def read_journal(path: Path, report: dict) -> dict | None:
    if observed(str(path)) is None:
        return None
    parent = open_home(str(path.parent))
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024 or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise LayoutError("unsafe_journal")
        contents = stream.read(1024 * 1024 + 1)
        if len(contents) > 1024 * 1024:
            raise LayoutError("unsafe_journal")
        journal = json.loads(contents)
    if (not isinstance(journal, dict) or not isinstance(journal.get("home"), str) or not os.path.isabs(journal["home"])
            or journal.get("phase") not in ("prepared", "applying", "applied", "rolling_back", "rolled_back")
            or not isinstance(journal.get("moves"), list)
            or hashlib.sha256(os.fsencode(journal["home"])).hexdigest()[:16] != path.stem):
        raise LayoutError("invalid_journal")
    if journal.get("registry") != report["source"]["manifest_sha256"]:
        if journal["home"] == report["home"]:
            raise LayoutError("journal_contract_changed")
        return None
    expected = {(row["from"], row["to"]) for row in report["moves"]}
    seen = set()
    for row in journal["moves"]:
        if not isinstance(row, dict) or (row.get("from"), row.get("to")) not in expected:
            raise LayoutError("invalid_journal")
        pair = (row["from"], row["to"])
        locations = [os.path.join(report["user_home"], value[2:]) if value.startswith("~/") else os.path.join(journal["home"], value) for value in pair]
        identity = row.get("identity")
        if (pair in seen or [row.get("source"), row.get("destination")] != locations or not isinstance(identity, dict)
                or any(type(identity.get(key)) is not int or identity[key] < 0 for key in ("device", "inode"))):
            raise LayoutError("invalid_journal")
        seen.add(pair)
    return journal


def journal_context(report: dict) -> tuple[Path, dict | None]:
    identity = hashlib.sha256(os.fsencode(report["home"])).hexdigest()[:16]
    path = Path(report["user_home"]) / ".tron-maintenance/layout-v2" / (identity + ".json")
    journal = read_journal(path, report)
    owned = {(row["from"], row["to"]) for row in journal["moves"]} if journal else set()
    if journal:
        for row in journal["moves"]:
            move_position(row)
    unclaimed = [row for row in report["moves"] if row["state"] == "done" and (row["from"], row["to"]) not in owned]
    if unclaimed:
        others = []
        fd = open_home(str(path.parent))
        try:
            with os.scandir(fd) as entries:
                candidates = [entry.name for entry in entries if re.fullmatch(r"[a-f0-9]{16}\.json", entry.name) and entry.name != path.name]
            if len(candidates) > 100:
                raise LayoutError("journal_budget_exceeded")
            for name in candidates:
                other = read_journal(path.parent / name, report)
                if other:
                    others.extend(other["moves"])
        finally:
            os.close(fd)
        for row in unclaimed:
            if not any(other["from"] == row["from"] and other["to"] == row["to"] and other["destination"] == row["destination"]
                       and (other["identity"]["device"], other["identity"]["inode"]) == (row["identity"]["device"], row["identity"]["inode"]) for other in others):
                raise LayoutError("unowned_destination")
    return path, journal


def execute_migration(home: str, rollback: bool, root: Path = ROOT) -> tuple[int, dict]:
    report = migration(home, root)
    if report["errors"]:
        return 2, report
    if report["blockers"] or any(row["refusals"] for row in report["moves"]):
        return 1, report
    try:
        journal_path, journal = journal_context(report)
    except (OSError, ValueError, KeyError, TypeError, LayoutError) as failure:
        report["blockers"].append(str(failure) if isinstance(failure, LayoutError) else "journal_unavailable")
        return 1, report
    report["journal"] = str(journal_path)
    with contextlib.ExitStack() as locks:
        try:
            lock_paths = sorted({Path(report["home"]) / RUNTIME_LOCK,
                                 Path(report["user_home"]) / ".tron-dev" / RUNTIME_LOCK})
            for lock in lock_paths:
                if observed(str(lock)) is not None:
                    report["blockers"].append("runtime_lock_present")
                    return 1, report
            if rollback and journal is None:
                report["blockers"].append("no_journal")
                return 1, report
            guards = [locks.enter_context(runtime_lock(lock)) for lock in lock_paths]
            current = migration(home, root)
            if current["errors"] or any(row["refusals"] for row in current["moves"]):
                report["blockers"].append("plan_changed")
                return 1, report
            _, journal = journal_context(current)
            if [(row["state"], row["identity"]) for row in current["moves"]] != [(row["state"], row["identity"]) for row in report["moves"]]:
                raise LayoutError("plan_changed")
            private_directory(journal_path.parent)
            if journal is None:
                journal = {"home": report["home"], "registry": report["source"]["manifest_sha256"],
                           "moves": [row for row in current["moves"] if row["state"] == "pending"], "phase": "prepared"}
                write_journal(journal_path, journal)
            moves = list(reversed(journal["moves"])) if rollback else journal["moves"]
            for row in moves:
                move_position(row)
                source, destination = (row["destination"], row["source"]) if rollback else (row["source"], row["destination"])
                if source == destination or destination.startswith(source + "/"):
                    raise LayoutError("destination_inside_source")
            for guard in guards:
                guard()
            journal["phase"] = "rolling_back" if rollback else "applying"
            write_journal(journal_path, journal)
            for row in moves:
                source, destination = (row["destination"], row["source"]) if rollback else (row["source"], row["destination"])
                for guard in guards:
                    guard()
                if move_position(row) == ("done" if rollback else "pending"):
                    private_directory(Path(destination).parent)
                    rename_exclusive(source, destination)
                if move_position(row) != ("pending" if rollback else "done"):
                    raise LayoutError("move_identity_changed")
            for guard in guards:
                guard()
            journal["phase"] = "rolled_back" if rollback else "applied"
            write_journal(journal_path, journal)
            report["state"] = journal["phase"]
            return 0, report
        except (OSError, ValueError, KeyError, TypeError, LayoutError) as failure:
            report["errors"].append({"path": str(journal_path), "reason": str(failure) if isinstance(failure, LayoutError) else type(failure).__name__,
                                     "errno": failure.errno if isinstance(failure, OSError) else None})
            return 1, report


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
    audit_parser.add_argument("--maintenance", help="also check this maintenance root's README index and backup-set rows")
    audit_parser.add_argument("--max-entries", type=positive, default=10000, help="scan budget; exhaustion exits 2 (default: 10000)")
    migrate_parser = commands.add_parser("migrate", help="offline retired-path plan, status, apply or inverse rollback, as JSON")
    migrate_parser.add_argument("--home", required=True, help="installation root; no default or implicit other-home access")
    mode = migrate_parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="every move with its identity, destination and refusals")
    mode.add_argument("--status", action="store_true", help="which moves are pending, done or in conflict")
    mode.add_argument("--apply", action="store_true", help="journal and rename offline; never start a Gateway")
    mode.add_argument("--rollback", action="store_true", help="invert journaled renames; carry newer data back")
    migrate_parser.add_argument("--json", action="store_true", help="JSON is always emitted")
    args = parser.parse_args(argv)
    if args.command == "audit":
        code, report = audit(args.home, args.max_entries, maintenance=args.maintenance)
        print(json.dumps(report, indent=2))
        return code
    if args.command == "migrate":
        code, report = execute_migration(args.home, args.rollback) if args.apply or args.rollback else migrate(args.home, args.status)
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
