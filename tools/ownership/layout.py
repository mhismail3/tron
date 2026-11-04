"""Repository layout rules checked with ownership (docs/restructure/structure-plan.md §4).

Every rule reads only the tracked path list and Git file modes, so it runs in the same pass
as ownership (index at pre-commit, any revision in verify). Each message names the fix.
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath

# Target root. Adding an entry is a deliberate edit here, reviewed with the charter's
# "Where things go" section, never a side effect of a new file.
ROOT_ENTRIES = {
    ".agents", ".github", ".gitattributes", ".gitignore", ".node-version", ".pi",
    "AGENTS.md", "README.md", "config", "docs", "packages", "scripts", "root.module.json",
}
# Executables other programs run by repo path. scripts/ top level holds only these and the
# commands listed in scripts/README.md; everything else lives in scripts/<area>/.
SCRIPT_TOP_FILES = {"README.md", "scripts.module.json"}
# Paths the installed (older) Gateway executes from this checkout. Moving one breaks the
# shipped app until the next Mac/Gateway checkpoint, so they never move and never vanish.
FROZEN = {"scripts/tron", "scripts/tron-ios-device", "scripts/tron_mac_replace.py"}
SCRIPT_ENTRIES = FROZEN | {"scripts/tron-node"}
TEST_NAME = re.compile(r"(^test[-_].+\.(py|sh|js|mjs)$)|(\.test\.(ts|mjs|js)$)|(Tests?\.swift$)")
SWIFT_TEST_ROOTS = ("/UITests/", "/E2ETests/", "/ProfilingTests/", "/SwiftAppUITests/", "/Tests/")
GATEWAY_TEST = re.compile(r"\.(integration|e2e)\.test\.(ts|mjs)$")
PURPOSE_LINES = 12


def problems(paths: list[str], modes: dict[str, str], read) -> list[str]:
    out: list[str] = []
    for path in sorted(FROZEN - set(paths)):
        out.append(f"layout: {path} is missing: the installed Gateway executes this path; restore it "
                   f"(it may only change content, never move)")
    tops = sorted({p.split("/", 1)[0] for p in paths})
    for top in tops:
        if top not in ROOT_ENTRIES and not top.endswith(".module.json"):
            out.append(f"layout: root entry {top!r} is not in the layout; put it under scripts/, docs/, config/ "
                       f"or a package (AGENTS.md 'Where things go'), or delete it")
    for path in paths:
        parts = path.split("/")
        name = parts[-1]
        if len(parts) == 1 and name.endswith(".module.json") and name != "root.module.json":
            out.append(f"layout: {path}: only root.module.json lives at the root; move the manifest beside the files it owns")
        if parts[0] == "scripts":
            if len(parts) == 2 and name not in SCRIPT_TOP_FILES and path not in SCRIPT_ENTRIES:
                out.append(f"layout: {path}: scripts/ top level holds only scripts/tron, tron-node and the frozen "
                           f"entry points; put it in scripts/<area>/ and add a scripts/tron subcommand if people run it")
            if len(parts) == 2 and TEST_NAME.search(name):
                out.append(f"layout: {path}: tests live beside their tool in scripts/<area>/, not at scripts/ top level")
            if len(parts) == 3 and name.endswith(".module.json") and name != f"{parts[1]}.module.json":
                out.append(f"layout: {path}: an area manifest is named after its directory: scripts/{parts[1]}/{parts[1]}.module.json")
        tooling = parts[0] == "scripts" or (parts[0] == "packages" and "scripts" in parts[2:-1])
        if tooling and TEST_NAME.search(name) is None and (name.endswith((".py", ".sh", ".mjs", ".js", ".ts"))
                                                          or modes.get(path) == "100755"):
            if not _has_purpose(read(path)):
                out.append(f"layout: {path}: add a one-line purpose comment in its first {PURPOSE_LINES} lines "
                           f"(what it does, who runs it); the ledger and scripts/README.md read it")
        if TEST_NAME.search(name):
            if parts[0] in ("docs", ".agents", ".github", "config") or len(parts) == 1:
                out.append(f"layout: {path}: tests live beside the code they prove, never in {parts[0]}/")
            if name.endswith(".swift") and not any(root in "/" + path for root in SWIFT_TEST_ROOTS):
                out.append(f"layout: {path}: Swift tests belong in a test target directory (UITests/, E2ETests/, "
                           f"ProfilingTests/, SwiftAppUITests/, Tests/), not app sources")
            if path.startswith("packages/gateway/") and name.endswith((".ts", ".mjs")) and not GATEWAY_TEST.search(name):
                out.append(f"layout: {path}: Gateway tests are named *.integration.test.ts or *.e2e.test.ts "
                           f"(packages/gateway/test-support/README.md)")
            if path.startswith("packages/gateway/src/") and "/tests/" in path:
                out.append(f"layout: {path}: Gateway tests sit beside their subject; move it out of tests/ into the module directory")
    return out


COMMENT = re.compile(r"^(#|//|\*|/\*\*?|\"\"\"|''')\s*")


def purpose(blob: bytes) -> str:
    """The first descriptive comment or docstring line: a tooling file's ledger purpose."""
    for line in blob[:4096].decode("utf-8", "replace").splitlines()[:PURPOSE_LINES]:
        if line.startswith("#!") or not COMMENT.match(line.strip()):
            continue
        text = COMMENT.sub("", line.strip()).strip().strip('"').strip()
        if len(text) > 8:
            return text[:140]
    return ""


def _has_purpose(blob: bytes) -> bool:
    return bool(purpose(blob))
