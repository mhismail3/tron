#!/usr/bin/env python3
"""Check that every tracked path has exactly one module owner (tools/ownership/README.md)."""

from __future__ import annotations

import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent.parent
SUFFIX = ".module.json"
STEM = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LAYERS = {f"L{n}" for n in range(6)}
EDGE_KINDS = {"registration", "spawn", "fs-read", "generated", "wire"}
RISK_CLASSES = {"kernel", "contracts", "persistence", "security", "lifecycle", "ios-ui", "mac-installer"}
BUDGETS = {"lines", "doc"}
FIELDS = {"layer", "owns", "dependsOn", "dynamicEdges", "capabilities", "verify", "riskClass", "exceptions"}
EDGE_FIELDS = {"to", "kind", "via", "why"}
EXCEPTION_FIELDS = {"path", "budget", "reason", "exit"}
FORBIDDEN = set("[]{}\\")


class GitError(Exception):
    pass


def git(*args: str) -> bytes:
    done = subprocess.run(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if done.returncode != 0:
        raise GitError(done.stderr.decode(errors="replace").strip() or f"git {args[0]} failed")
    return done.stdout


def inventory(rev: str | None) -> tuple[list[str], callable]:
    """Tracked paths plus a reader for their content: the index and working tree, or one commit."""
    if rev is None:
        paths = [p.decode("utf-8", "surrogateescape") for p in git("ls-files", "-z").split(b"\0") if p]
        return sorted(paths), lambda path: (ROOT / path).read_bytes()
    try:
        sha = git("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}").decode().strip()
    except GitError:
        raise GitError(f"unknown revision {rev!r}") from None
    paths = [p.decode("utf-8", "surrogateescape")
             for p in git("ls-tree", "-r", "-z", "--name-only", sha).split(b"\0") if p]
    return sorted(paths), lambda path: git("cat-file", "blob", f"{sha}:{path}")


def pattern_problem(pattern: object) -> str | None:
    if not isinstance(pattern, str) or not pattern:
        return "must be a non-empty string"
    if pattern.startswith("/") or pattern.endswith("/"):
        return "must be relative, without a leading or trailing '/'"
    if FORBIDDEN & set(pattern):
        return "may use only '*', '?' and whole-segment '**' as wildcards"
    for segment in pattern.split("/"):
        if segment in ("", ".", ".."):
            return "has an empty, '.' or '..' segment (no escapes)"
        if "**" in segment and segment != "**":
            return "uses '**' inside a segment; '**' must be a whole segment"
    return None


def matches(pattern: list[str], path: list[str]) -> bool:
    """Segment match: '*'/'?' stay within one segment, '**' spans zero or more segments."""
    if not pattern:
        return not path
    if pattern[0] == "**":
        return any(matches(pattern[1:], path[i:]) for i in range(len(path) + 1))
    return bool(path) and fnmatch.fnmatchcase(path[0], pattern[0]) and matches(pattern[1:], path[1:])


def module_id(manifest: str) -> str:
    parts = manifest.split("/")
    package = parts[1] if parts[0] == "packages" and len(parts) > 2 else "repo"
    return f"{package}/{parts[-1][:-len(SUFFIX)]}"


def folder_references(paths: list[str], read) -> set[str]:
    """Directories an XcodeGen spec copies whole (`type: folder`); they cannot exclude a manifest."""
    found = set()
    for spec in (p for p in paths if p.startswith("packages/") and p.endswith("/project.yml")):
        base = PurePosixPath(spec).parent
        entry = None
        for line in read(spec).decode("utf-8", "replace").splitlines():
            start = re.match(r"^\s*- path:\s*(.+?)\s*$", line)
            if start:
                entry = start.group(1).strip("\"'")
            elif entry and re.match(r"^\s+type:\s*folder\s*$", line):
                parts = []
                for part in (base / entry).parts:
                    if part == "..":
                        parts.pop()
                    else:
                        parts.append(part)
                found.add("/".join(parts))
            elif not line.startswith("      "):
                entry = None
    return found


def unique_list(value: object, field: str, errors: list[str]) -> list:
    if not isinstance(value, list):
        errors.append(f"{field} must be a list")
        return []
    seen = []
    for item in value:
        if item in seen:
            errors.append(f"{field} repeats {json.dumps(item)}")
        else:
            seen.append(item)
    return seen


def strings(value: object, field: str, errors: list[str]) -> list[str]:
    items = unique_list(value, field, errors)
    good = [item for item in items if isinstance(item, str) and item.strip()]
    if len(good) != len(items):
        errors.append(f"{field} entries must be non-empty strings")
    return good


def one_of(value: object, options) -> bool:
    return isinstance(value, str) and value in options


def reject_duplicate_keys(pairs):
    keys = [key for key, _ in pairs]
    duplicate = sorted({key for key in keys if keys.count(key) > 1})
    if duplicate:
        raise ValueError(f"duplicate key {duplicate[0]!r}")
    return dict(pairs)


def check(rev: str | None = None) -> tuple[dict, list[str]]:
    paths, read = inventory(rev)
    tracked = set(paths)
    manifests = [p for p in paths if p.endswith(SUFFIX)]
    errors: list[str] = []
    modules: dict[str, dict] = {}
    by_id: dict[str, list[str]] = {}

    copied_whole = folder_references(paths, read)
    packages = {str(PurePosixPath(p).parent) for p in paths if PurePosixPath(p).name == "Package.swift"}
    for manifest in manifests:
        name, folder = PurePosixPath(manifest).name, str(PurePosixPath(manifest).parent)
        if not STEM.match(name[:-len(SUFFIX)]):
            errors.append(f"{manifest}: name must be <lowercase-kebab-name>{SUFFIX}")
            continue
        by_id.setdefault(module_id(manifest), []).append(manifest)
        for whole in copied_whole:
            if folder == whole or folder.startswith(whole + "/"):
                errors.append(f"{manifest}: inside XcodeGen folder reference {whole}, which copies it into the bundle")
        for package in packages:
            prefix = "" if package == "." else package + "/"
            if manifest.startswith(prefix) and folder != package:
                errors.append(f"{manifest}: inside SwiftPM package {package}; place it beside Package.swift")
        problems: list[str] = []
        try:
            data = json.loads(read(manifest).decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
        except OSError as error:
            errors.append(f"{manifest}: unreadable: {error.strerror or error}")
            continue
        except (ValueError, UnicodeDecodeError) as error:
            errors.append(f"{manifest}: invalid JSON: {error}")
            continue
        if not isinstance(data, dict):
            errors.append(f"{manifest}: must be a JSON object")
            continue
        for key in sorted(set(data) - FIELDS):
            problems.append(f"unknown key {key!r}")
        for key in ("layer", "owns"):
            if key not in data:
                problems.append(f"missing required key {key!r}")
        if "layer" in data and not one_of(data["layer"], LAYERS):
            problems.append("layer must be one of L0..L5")
        owns = unique_list(data.get("owns", []), "owns", problems)
        if "owns" in data and not owns:
            problems.append("owns must not be empty")
        patterns = []
        for pattern in owns:
            problem = pattern_problem(pattern)
            if problem:
                problems.append(f"owns entry {json.dumps(pattern)} {problem}")
            else:
                patterns.append(pattern)
        errors.extend(f"{manifest}: {p}" for p in problems)
        modules[manifest] = {"id": module_id(manifest), "folder": folder, "data": data,
                             "patterns": patterns, "owned": []}

    for module_key, files in sorted(by_id.items()):
        if len(files) > 1:
            errors.append(f"duplicate module id {module_key}: {', '.join(files)}")

    # Exactly-one ownership: one owns entry across all manifests per tracked path.
    hits: dict[str, list[tuple[str, str]]] = {}
    for manifest, module in modules.items():
        prefix = "" if module["folder"] == "." else module["folder"] + "/"
        local = [p for p in paths if p.startswith(prefix)]
        for pattern in module["patterns"]:
            split = pattern.split("/")
            matched = [p for p in local if matches(split, p[len(prefix):].split("/"))]
            if not matched:
                errors.append(f"{manifest}: owns entry {json.dumps(pattern)} matches no tracked path")
            for path in matched:
                hits.setdefault(path, []).append((manifest, pattern))
    for path in paths:
        owners = hits.get(path, [])
        if not owners:
            errors.append(f"unowned: {path}")
        elif len(owners) > 1:
            claims = "; ".join(f"{m} {json.dumps(p)}" for m, p in owners)
            errors.append(f"owned more than once: {path} ({claims})")
        else:
            modules[owners[0][0]]["owned"].append(path)
            if path in modules and owners[0][0] != path:
                errors.append(f"{path}: must own itself, not be owned by {owners[0][0]}")

    ids = {module["id"] for module in modules.values()}
    for manifest, module in modules.items():
        data, own_id, problems = module["data"], module["id"], []
        for target in strings(data.get("dependsOn", []), "dependsOn", problems):
            if target == own_id or target not in ids:
                problems.append(f"dependsOn {target!r} is not another module id")
        for edge in unique_list(data.get("dynamicEdges", []), "dynamicEdges", problems):
            if not isinstance(edge, dict):
                problems.append("dynamicEdges entries must be objects")
                continue
            for key in sorted(set(edge) - EDGE_FIELDS):
                problems.append(f"dynamicEdges entry has unknown key {key!r}")
            for key in sorted({"to", "kind", "why"} - set(edge)):
                problems.append(f"dynamicEdges entry is missing {key!r}")
            if "to" in edge and (edge["to"] == own_id or not one_of(edge["to"], ids)):
                problems.append(f"dynamicEdges to {edge['to']!r} is not another module id")
            if "kind" in edge and not one_of(edge["kind"], EDGE_KINDS):
                problems.append(f"dynamicEdges kind must be one of {', '.join(sorted(EDGE_KINDS))}")
            if "via" in edge and not one_of(edge["via"], tracked):
                problems.append(f"dynamicEdges via {edge['via']!r} is not a tracked repo-relative path")
            if "why" in edge and not (isinstance(edge["why"], str) and edge["why"].strip()):
                problems.append("dynamicEdges why must be a non-empty string")
        strings(data.get("capabilities", []), "capabilities", problems)
        for command in strings(data.get("verify", []), "verify", problems):
            if not command.startswith("scripts/tron "):
                problems.append(f"verify {command!r} must be a 'scripts/tron …' command")
        for risk in unique_list(data.get("riskClass", []), "riskClass", problems):
            if not one_of(risk, RISK_CLASSES):
                problems.append(f"riskClass {risk!r} must be one of {', '.join(sorted(RISK_CLASSES))}")
        prefix = "" if module["folder"] == "." else module["folder"] + "/"
        for item in unique_list(data.get("exceptions", []), "exceptions", problems):
            if not isinstance(item, dict) or set(item) != EXCEPTION_FIELDS:
                problems.append("exceptions entries need exactly path, budget, reason and exit")
                continue
            if not one_of(item["budget"], BUDGETS):
                problems.append("exceptions budget must be lines or doc")
            if not all(isinstance(item[k], str) and item[k].strip() for k in ("reason", "exit")):
                problems.append("exceptions reason and exit must be non-empty strings")
            if pattern_problem(item["path"]) or prefix + str(item["path"]) not in module["owned"]:
                problems.append(f"exceptions path {item['path']!r} is not a file this module owns")
        errors.extend(f"{manifest}: {p}" for p in problems)

    summary = {m["id"]: {"manifest": k, "layer": m["data"].get("layer"), "owned": m["owned"],
                         "dependsOn": [d for d in (m["data"].get("dependsOn") if isinstance(m["data"].get("dependsOn"), list)
                                                   else []) if isinstance(d, str)]}
               for k, m in modules.items()}
    return {"tracked": paths, "modules": dict(sorted(summary.items()))}, sorted(set(errors))


USAGE = """usage: scripts/tron ownership [<rev>] [--modules]
Checks every tracked path has exactly one <name>.module.json owner (tools/ownership/README.md).
Without <rev>: the index's paths with working-tree contents. Exit 0 clean, 1 violations, 2 usage/Git."""


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--modules"]
    if any(a.startswith("-") for a in args) or len(args) > 1:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        result, errors = check(args[0] if args else None)
    except GitError as error:
        print(f"ownership: {error}", file=sys.stderr)
        return 2
    if "--modules" in argv:
        for key, module in result["modules"].items():
            print(f"{key}\t{module['layer']}\t{len(module['owned'])}\t{module['manifest']}")
    for error in errors:
        print(error)
    state = f"{len(errors)} violation(s)" if errors else "every path owned exactly once"
    print(f"ownership: {len(result['modules'])} modules, {len(result['tracked'])} tracked paths, {state}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
