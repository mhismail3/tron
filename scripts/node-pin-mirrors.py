#!/usr/bin/env python3
"""The compiled-in copies of the Node pins, owned by `scripts/tron-node pin` (#245).

`.node-version` and `config/ci-toolchain.env` are the authority. A few trust
roots cannot read them at run time: the signed Mac app and the Gateway payload's
deploy script verify an installed npm tree against constants compiled into
themselves, and the native Gateway client pins the Node C headers it builds
against. Each keeps an exact literal, and this file is the one list of them:

  check   exit 1 naming every literal that differs from the authority
  write   rewrite every literal from the authority (and, with --headers DIR,
          the C header digests from that verified Node archive's include/node)
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADERS_PIN = "packages/mac-app/native-gateway-client/node-headers.json"
# (path, pattern whose group 1 is the literal, authority key)
LITERALS = [
    ("scripts/gateway-payload-deploy.mjs", r'^export const PINNED_NPM_VERSION = "([^"]*)";$', "TRON_NODE_NPM_VERSION"),
    ("scripts/gateway-payload-deploy.mjs", r'^export const PINNED_NPM_TREE_SHA256 = "([^"]*)";$', "TRON_NODE_NPM_TREE_SHA256"),
    ("packages/mac-app/Sources/Server/Paths/GatewayPayloadStore.swift",
     r'^\s*packageObject\["version"\] as\? String == "([^"]*)",$', "TRON_NODE_NPM_VERSION"),
    ("packages/mac-app/Sources/Server/Paths/GatewayPayloadStore.swift",
     r'^\s*npmRuntimeTreeDigest\(runtime, fileManager: fileManager\) == "([^"]*)" else', "TRON_NODE_NPM_TREE_SHA256"),
]


def authority() -> dict[str, str]:
    values = {"node": (ROOT / ".node-version").read_text().strip()}
    for line in (ROOT / "config/ci-toolchain.env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            name, value = line.split("=", 1)
            values[name] = value
    return values


def literal_spans(text: str, pattern: str) -> list[re.Match[str]]:
    return list(re.finditer(pattern, text, re.M))


def check() -> list[str]:
    values, problems = authority(), []
    for path, pattern, key in LITERALS:
        matches = literal_spans((ROOT / path).read_text(), pattern)
        if len(matches) != 1:
            problems.append(f"{path}: expected one {key} literal, found {len(matches)}")
        elif matches[0].group(1) != values[key]:
            problems.append(f"{path}: {key} literal {matches[0].group(1)} differs from {values[key]}")
    headers = json.loads((ROOT / HEADERS_PIN).read_text())
    if headers.get("version") != values["node"]:
        problems.append(f"{HEADERS_PIN}: version {headers.get('version')} differs from .node-version {values['node']}")
    return problems


def write(header_dir: Path | None) -> None:
    values = authority()
    for path, pattern, key in LITERALS:
        file = ROOT / path
        text = file.read_text()
        matches = literal_spans(text, pattern)
        if len(matches) != 1:
            sys.exit(f"node-pin-mirrors: {path}: expected one {key} literal, found {len(matches)}")
        start, end = matches[0].span(1)
        file.write_text(text[:start] + values[key] + text[end:])
    pin_path = ROOT / HEADERS_PIN
    pin = json.loads(pin_path.read_text())
    pin["version"] = values["node"]
    if header_dir is not None:
        pin["sha256"] = {name: hashlib.sha256((header_dir / name).read_bytes()).hexdigest() for name in pin["sha256"]}
    pin_path.write_text(json.dumps(pin, indent=2) + "\n")


if __name__ == "__main__":
    if sys.argv[1:] == ["check"]:
        found = check()
        for problem in found:
            print(f"node-pin-mirrors: {problem}", file=sys.stderr)
        sys.exit(1 if found else 0)
    if sys.argv[1:2] == ["write"] and len(sys.argv) in (2, 4) and (len(sys.argv) == 2 or sys.argv[2] == "--headers"):
        write(Path(sys.argv[3]) if len(sys.argv) == 4 else None)
        sys.exit(0)
    sys.exit("usage: scripts/node-pin-mirrors.py check | write [--headers DIR]")
