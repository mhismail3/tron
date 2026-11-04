"""Repository layout rules that `scripts/tron ownership` checks when root.module.json declares a layout.

The rules read only tracked paths, their Git modes and contents, so they run in the same pass
as ownership on the index or on any revision. Each message names its fix. The seeded lists in
root.module.json `layout` only shrink (tools/ownership/README.md, "Layout").
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath

KEYS = {"root", "scriptsTop", "frozen", "unmigrated"}
RULES = ("purpose", "gateway-test-name", "gateway-test-dir")
TEST_NAME = re.compile(r"(^test[-_].+\.(py|sh|js|mjs)$)|(\.test\.(ts|mjs|js)$)|(Tests?\.swift$)")
SWIFT_TEST_DIRS = {"UITests", "E2ETests", "ProfilingTests", "SwiftAppUITests", "Tests"}
NO_TESTS = {"docs", "config", ".agents", ".github"}
GATEWAY_TEST = re.compile(r"\.(integration|e2e)\.test\.(ts|mjs)$")
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
    if not (parts[0] in ("scripts", "tools") or (parts[0] == "packages" and "scripts" in parts[2:-1])):
        return False
    return not TEST_NAME.search(parts[-1]) and (parts[-1].endswith(TOOLING_SUFFIXES) or mode == "100755")


def schema(layout: object) -> list[str]:
    if not isinstance(layout, dict):
        return ["root.module.json: layout must be an object"]
    out = [f"root.module.json: layout has unknown key {key!r}" for key in sorted(set(layout) - KEYS)]
    out += [f"root.module.json: layout is missing {key!r}" for key in ("root", "scriptsTop", "frozen") if key not in layout]
    for key in ("root", "scriptsTop", "frozen"):
        value = layout.get(key, [])
        if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
            out.append(f"root.module.json: layout.{key} must be a list of paths")
    unmigrated = layout.get("unmigrated", {})
    if not isinstance(unmigrated, dict):
        out.append("root.module.json: layout.unmigrated must map a rule to paths")
    else:
        for rule, value in unmigrated.items():
            if rule not in RULES:
                out.append(f"root.module.json: layout.unmigrated has unknown rule {rule!r} (rules: {', '.join(RULES)})")
            if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
                out.append(f"root.module.json: layout.unmigrated.{rule} must be a list of paths")
    return out


def lists(layout: dict) -> dict[str, list[str]]:
    """Every shrink-only list by its display name."""
    out = {"root": layout.get("root", []), "scriptsTop": layout.get("scriptsTop", [])}
    for rule, value in (layout.get("unmigrated") or {}).items():
        out[f"unmigrated.{rule}"] = value
    return out


def rule_violations(paths: list[str], modes: dict[str, str], read) -> dict[str, dict[str, str]]:
    """Violations of the allowlistable rules, by rule then path."""
    found: dict[str, dict[str, str]] = {rule: {} for rule in RULES}
    for path in paths:
        parts = path.split("/")
        name = parts[-1]
        if is_tooling(path, modes.get(path, "")) and not purpose(read(path)):
            found["purpose"][path] = (f"layout: {path}: add a one-line purpose comment in its first {PURPOSE_LINES} lines "
                                      "(what it does, who runs it); `scripts/tron ownership --ledger` shows it")
        if path.startswith("packages/gateway/") and TEST_NAME.search(name) and name.endswith((".ts", ".mjs")):
            if not GATEWAY_TEST.search(name):
                found["gateway-test-name"][path] = (f"layout: {path}: Gateway tests are named *.integration.test.ts or "
                                                    "*.e2e.test.ts (packages/gateway/test-support/README.md)")
            if path.startswith("packages/gateway/src/") and "tests" in parts[3:-1]:
                found["gateway-test-dir"][path] = (f"layout: {path}: Gateway tests sit beside their subject; "
                                                   "move it out of tests/ into the module directory")
    return found


def problems(layout: dict, paths: list[str], modes: dict[str, str], read, base: dict | None) -> list[str]:
    out = schema(layout)
    if out:
        return out
    tracked = set(paths)
    tops = {path.split("/", 1)[0] for path in paths}
    root, scripts_top, frozen = set(layout["root"]), set(layout["scriptsTop"]), layout["frozen"]
    unmigrated = {rule: set(value) for rule, value in (layout.get("unmigrated") or {}).items()}

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

    for rule, violations in rule_violations(paths, modes, read).items():
        allowed = unmigrated.get(rule, set())
        out += [message for path, message in sorted(violations.items()) if path not in allowed]
        out += [f"layout: root.module.json layout.unmigrated.{rule} lists {path!r}, which no longer breaks that rule; "
                "remove it" for path in sorted(allowed - set(violations))]

    if base is not None and not schema(base):
        before = lists(base)
        for key, entries in lists(layout).items():
            for entry in sorted(set(entries) - set(before.get(key, []))):
                out.append(f"layout: root.module.json layout.{key} gained {entry!r} since origin/main; these lists only "
                           f"shrink: put the file where it belongs instead ({WHERE})")
    return out
