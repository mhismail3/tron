#!/usr/bin/env python3
"""Checks tracked source against the one Tron-home path registry.

The registry is packages/gateway/src/foundation/tron-home-layout.json; the
policy is docs/tron-home.md. `check` reads tracked source only.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
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


def registered(paths: dict, relative: str) -> bool:
    """True when a registry entry, pattern or owning subtree covers `relative`."""
    parts = relative.split("/")
    for index in range(len(parts), 0, -1):
        prefix = "/".join(parts[:index])
        for key, entry in paths.items():
            if key == prefix or ("*" in key and fnmatch.fnmatchcase(prefix, key)):
                if index == len(parts) or entry.get("subtree"):
                    return True
    return False


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
        owner = entry["owner"]
        if not owner.startswith(EXTERNAL_OWNERS) and owner not in known:
            problems.append(f"{key}: owner {owner} is not a module (scripts/tron ownership --modules)")
        parent = key.rsplit("/", 1)[0]
        if "/" in key and parent not in paths:
            problems.append(f"{key}: parent {parent} is not registered")
    return problems


# A Tron-home-relative literal: `.tron/<a>/<b>`, `".tron", "<a>"`, `".tron" / "<a>"`,
# Swift `tronHome...appendingPathComponent("<a>"`, or `join(tronHome, "<a>", "<b>"`.
LITERALS = [
    re.compile(r"\.tron/([\w.-]+)(?:/([\w.*-]+))?"),
    re.compile(r"""["']\.tron["']\s*[,/]\s*["']([\w.-]+)["'](?:\s*[,/]\s*["']([\w.*-]+)["'])?"""),
    re.compile(r'\b\w*[hH]ome\b[^\n]*?appendingPathComponent\(\s*"([\w.-]+)(?:/([\w.*-]+))?"'),
    re.compile(r"""\b(?:join|resolve)\(\s*[\w.]*(?:tronHome|tron_home|TRON_HOME|\bhome)\b[^,()]*,\s*["']([\w.-]+)["'](?:\s*,\s*["']([\w.*-]+)["'])?"""),
]
# The last two patterns also match other homes (the user's, a bundle's): unless the
# receiver names the Tron home, only a first segment that is a registered root counts.
TRON_RECEIVER = re.compile(r"tronHome|tron_home|TRON_HOME|TronHome")
GATEWAY_JOIN = LITERALS[3]
SOURCE_ROOTS = ("packages/gateway/src", "packages/gateway/scripts", "packages/mac-app/Sources", "packages/mac-app/scripts", "scripts", "tools")
SOURCE_SUFFIXES = {".ts", ".mjs", ".js", ".py", ".swift", ".c", ".sh"}
TEST_NAME = re.compile(r"((^|/)test[-_][^/]*$|[.-]test\.|\.(integration|e2e|lock)\.|Tests?/|/tests/)")
# The registry module itself, and the tool that reads the registry, name paths by design.
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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron home-layout", description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="registry is valid and tracked source names only registered Tron-home paths")
    parser.parse_args(argv)
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
