#!/usr/bin/env python3
"""Print a finished result bundle's failures as a short, agent-readable block.

The one owner of compact xcresult failure output for `scripts/tron-ios-test` and
the E2E harness. `--build` lists compiler/build errors as `error: path:line: message` (`error:
message` without a source location);
`--tests` lists each failure message as `failure: test: message` (`failure: message`
when no test case encloses it). The raw xcodebuild log stays
the evidence: this summary is optional, never changes a caller's status and is
silent when the bundle is missing or unreadable.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from urllib.parse import parse_qs, unquote, urlsplit

LIMIT = 20


def xcresult(bundle: str, *query: str) -> object | None:
    try:
        completed = subprocess.run(
            ["xcrun", "xcresulttool", "get", *query, "--path", bundle],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None


def location(source_url: str, root: str) -> str:
    """`file:///…/File.swift#StartingLineNumber=N…` as `relative/File.swift:N`.

    xcresult's line fragment is zero-based; compilers and editors count from one.
    """
    parts = urlsplit(source_url)
    path = unquote(parts.path) if parts.scheme == "file" else source_url
    if root and path.startswith(root.rstrip("/") + "/"):
        path = path[len(root.rstrip("/")) + 1:]
    fragment = parse_qs(parts.fragment)
    line = fragment.get("StartingLineNumber", [""])[0]
    return f"{path}:{int(line) + 1}" if line.isdigit() else path


def build_lines(document: object, root: str) -> list[str]:
    if not isinstance(document, dict):
        return []
    lines = []
    for issue in document.get("errors") or []:
        if not isinstance(issue, dict):
            continue
        message = " ".join(str(issue.get("message", "")).split())
        source = issue.get("sourceURL")
        lines.append(f"{location(source, root)}: {message}" if source else message)
    return lines


def test_lines(document: object) -> list[str]:
    lines: list[str] = []

    def walk(value: object, test: str | None) -> None:
        if isinstance(value, dict):
            if value.get("nodeType") == "Test Case":
                test = value.get("name") or test
            if value.get("nodeType") == "Failure Message":
                message = " ".join(str(value.get("name", "assertion failed")).split())
                lines.append(f"{test}: {message}" if test else message)
            for child in value.values():
                walk(child, test)
        elif isinstance(value, list):
            for child in value:
                walk(child, test)

    walk(document, None)
    return lines


def emit(title: str, prefix: str, lines: list[str]) -> None:
    if not lines:
        return
    print(f"{title} ({len(lines)}):")
    for line in lines[:LIMIT]:
        print(f"  {prefix}: {line}")
    if len(lines) > LIMIT:
        print(f"  ... {len(lines) - LIMIT} more in the result bundle")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("bundle")
    parser.add_argument("--build", action="store_true", help="list build errors")
    parser.add_argument("--tests", action="store_true", help="list test failure messages")
    parser.add_argument("--root", default="", help="print source paths relative to this directory")
    arguments = parser.parse_args()
    if not os.path.isdir(arguments.bundle):
        return 0
    root = os.path.realpath(arguments.root) if arguments.root else ""
    if arguments.build:
        emit("build errors", "error", build_lines(xcresult(arguments.bundle, "build-results"), root))
    if arguments.tests:
        emit("test failures", "failure", test_lines(xcresult(arguments.bundle, "test-results", "tests")))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
