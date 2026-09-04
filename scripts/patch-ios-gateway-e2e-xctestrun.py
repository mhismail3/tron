#!/usr/bin/env python3
"""Patch the unique Tron unit-test target in a generated xctestrun plist."""

from __future__ import annotations

import os
import plistlib
import stat
import sys
import tempfile
from pathlib import Path

MAX_XCTESTRUN_BYTES = 16 * 1024 * 1024
TARGET_BLUEPRINT = "TronMobileTests"
ENVIRONMENT_KEYS = (
    "TRON_E2E_PORT",
    "TRON_E2E_CODE",
    "TRON_E2E_WORKSPACE",
    "TRON_E2E_PI_VERSION",
)


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def patch_document(document: object, values: dict[str, str]) -> dict[str, object]:
    if not isinstance(document, dict):
        fail("xctestrun root must be a dictionary")
    configurations = document.get("TestConfigurations")
    if not isinstance(configurations, list):
        fail("xctestrun TestConfigurations is missing or malformed")

    matches: list[dict[str, object]] = []
    for configuration in configurations:
        if not isinstance(configuration, dict):
            fail("xctestrun contains a malformed test configuration")
        targets = configuration.get("TestTargets")
        if not isinstance(targets, list):
            fail("xctestrun test configuration has no TestTargets array")
        if configuration.get("IsEnabled") is not True:
            continue
        for target in targets:
            if not isinstance(target, dict):
                fail("xctestrun contains a malformed test target")
            if target.get("BlueprintName") == TARGET_BLUEPRINT and target.get("IsUITestBundle") is not True:
                matches.append(target)

    if len(matches) != 1:
        fail(f"xctestrun must contain exactly one enabled {TARGET_BLUEPRINT} unit-test target (found {len(matches)})")

    target = matches[0]
    current = target.get("EnvironmentVariables")
    if current is None:
        current = {}
        target["EnvironmentVariables"] = current
    if not isinstance(current, dict):
        fail("xctestrun EnvironmentVariables is malformed")
    current.update(values)
    return document


def patch_file(path: Path, values: dict[str, str]) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        fail("xctestrun must be a regular non-symlink file")
    if info.st_size <= 0 or info.st_size > MAX_XCTESTRUN_BYTES:
        fail("xctestrun is empty or exceeds its byte limit")
    with path.open("rb") as handle:
        document = plistlib.load(handle)
    encoded = plistlib.dumps(patch_document(document, values))
    if len(encoded) > MAX_XCTESTRUN_BYTES:
        fail("patched xctestrun exceeds its byte limit")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, stat.S_IMODE(info.st_mode))
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print("usage: patch-ios-gateway-e2e-xctestrun.py XCTESTRUN PORT CODE WORKSPACE PI_VERSION", file=sys.stderr)
        return 64
    path = Path(argv[1])
    values = dict(zip(ENVIRONMENT_KEYS, argv[2:]))
    try:
        patch_file(path, values)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"xctestrun patch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
