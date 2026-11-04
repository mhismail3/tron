"""Repository layout rules that `scripts/tron ownership` checks when root.module.json declares a layout.

The rules read only tracked paths, their Git modes and contents, so they run in the same pass
as ownership on the index or on any revision. Each message names its fix. The seeded lists in
root.module.json `layout` only shrink (tools/ownership/README.md, "Layout").
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath

KEYS = {"root", "scriptsTop", "frozen"}
TEST_NAME = re.compile(r"(^test[-_].+\.(py|sh|js|mjs)$)|(\.test\.(ts|mjs|js)$)|(Tests?\.swift$)")
SWIFT_TEST_DIRS = {"UITests", "E2ETests", "ProfilingTests", "SwiftAppUITests", "Tests"}
NO_TESTS = {"docs", "config", ".agents", ".github"}
TOOLING_SUFFIXES = (".py", ".sh", ".mjs", ".js", ".ts")
PURPOSE_LINES = 12
COMMENT = re.compile(r"^(#|//|\*|/\*\*?|\"\"\"|''')\s*")
DIRECTIVE = re.compile(r"^(shellcheck |-\*-|eslint|@ts-|noqa|type: |pylint|coding[:=]|vim?:|SPDX-|Copyright|swiftlint)", re.I)
WHERE = "AGENTS.md \"Where things go\""


def purpose(blob: bytes) -> str:
    """The first prose comment or docstring line in a file's head; directives do not count."""
    for line in blob[:4096].decode("utf-8", "replace").splitlines()[:PURPOSE_LINES]:
        stripped = line.strip()
        if stripped.startswith("#!") or not COMMENT.match(stripped):
            continue
        text = COMMENT.sub("", stripped).strip().strip("\"'").strip()
        if DIRECTIVE.match(text):
            continue
        if len(text) > 8 and " " in text:
            return text[:140]
    return ""


def is_tooling(path: str, mode: str) -> bool:
    parts = path.split("/")
    if not (parts[0] in ("scripts", "tools") or (parts[0] == "packages" and len(parts) > 3 and parts[2] == "scripts")):
        return False
    return not TEST_NAME.search(parts[-1]) and (parts[-1].endswith(TOOLING_SUFFIXES) or mode == "100755")


def schema(layout: object) -> list[str]:
    if not isinstance(layout, dict):
        return ["root.module.json: layout must be an object"]
    out = [f"root.module.json: layout has unknown key {key!r}" for key in sorted(set(layout) - KEYS)]
    out += [f"root.module.json: layout is missing {key!r}" for key in sorted(KEYS) if key not in layout]
    for key in sorted(KEYS):
        value = layout.get(key, [])
        if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
            out.append(f"root.module.json: layout.{key} must be a list of paths")
    return out


def problems(layout: dict, paths: list[str], modes: dict[str, str], read, base: dict | None = None) -> list[str]:
    """Layout violations of one tree; with `base` (the layout at the merge base), also what this change grew."""
    out = schema(layout)
    if out:
        return out
    tracked = set(paths)
    tops = {path.split("/", 1)[0] for path in paths}
    root, scripts_top, frozen = set(layout["root"]), set(layout["scriptsTop"]), layout["frozen"]

    for top in sorted(tops - root):
        out.append(f"layout: root entry {top!r} is not in the layout; put it under scripts/, docs/, config/ or a "
                   f"package ({WHERE}), or delete it")
    for entry in sorted(root - tops):
        out.append(f"layout: root.module.json layout.root lists {entry!r}, which is not tracked; remove it")
    for entry in sorted(scripts_top - tracked):
        out.append(f"layout: root.module.json layout.scriptsTop lists {entry!r}, which is not tracked; remove it")
    for path in frozen:
        if path not in tracked:
            out.append(f"layout: {path} is missing: code older than this checkout runs this path; restore it "
                       "(change its content, never its path)")

    for path in paths:
        parts = path.split("/")
        name = parts[-1]
        if is_tooling(path, modes.get(path, "")) and not purpose(read(path)):
            out.append(f"layout: {path}: add a one-line purpose comment in its first {PURPOSE_LINES} lines "
                       "(what it does, who runs it); `scripts/tron ownership --ledger` shows it")
        if parts[0] == "scripts" and len(parts) == 2 and path not in scripts_top:
            if TEST_NAME.search(name):
                out.append(f"layout: {path}: tests live beside the tool they prove (tools/<tool>/ or scripts/<area>/), "
                           "not at scripts/ top level")
            else:
                out.append(f"layout: {path}: scripts/ top level holds only the commands listed in root.module.json "
                           "layout.scriptsTop; put it in scripts/<area>/ with its tests and <area>.module.json, and add "
                           "a scripts/tron subcommand if people run it")
        if TEST_NAME.search(name):
            if len(parts) == 1 or parts[0] in NO_TESTS:
                where = "the repository root" if len(parts) == 1 else f"{parts[0]}/"
                out.append(f"layout: {path}: tests live beside the code they prove, never in {where}")
            if name.endswith(".swift") and not SWIFT_TEST_DIRS.intersection(PurePosixPath(path).parts[:-1]):
                out.append(f"layout: {path}: Swift tests belong in a test target (UITests/, E2ETests/, ProfilingTests/, "
                           "SwiftAppUITests/, Tests/), not app sources")

    if base is not None and not schema(base):
        for key in ("root", "scriptsTop"):
            for entry in sorted(set(layout[key]) - set(base[key])):
                out.append(f"layout: root.module.json layout.{key} gained {entry!r} since origin/main; these lists only "
                           f"shrink: put the file where it belongs instead ({WHERE})")
        for path in sorted(set(base["frozen"]) - set(frozen) - tracked):
            out.append(f"layout: {path} was frozen at origin/main and this change unfreezes and removes it; code older "
                       "than this checkout still runs it, so keep it until the maintainer's checkpoint ships without it")
    return out
