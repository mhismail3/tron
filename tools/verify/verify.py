#!/usr/bin/env python3
"""scripts/tron verify: static checks plus the tests each manifest selects (tools/verify/README.md)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import ownership  # noqa: E402  (the one ownership authority)
sys.path.insert(0, str(ROOT / "tools" / "layers"))
import swift_index  # noqa: E402  (the one authority on a fresh iOS index and build stamp)
sys.path.insert(0, str(ROOT / "tools" / "verify"))
import vitest_configs  # noqa: E402  (the one reader of the Gateway's listing Vitest configs)
import mini  # noqa: E402  (the test-host pool's one owner)

GATEWAY = "packages/gateway"
RELAY = "packages/push-relay"
CORE = "packages/core"
MAC = "packages/mac-app"
# A change here reaches everything above it, so it selects every lock.
WIDENING_LAYERS = {"L0", "L1", "L2"}
WIDENING_MODULES = {"gateway/package", "gateway/test-support", "gateway/pi-sdk"}
# Locks not named `*.lock.integration.test.ts`: the Pi SDK seam's behavior trace and corpus.
NAMED_LOCKS = {f"{GATEWAY}/src/e2e/sessions/sdk-behavior-trace.integration.test.ts",
               f"{GATEWAY}/src/e2e/sessions/pi-persisted-state-corpus.integration.test.ts"}
SKIPPABLE = ("ios", "mac", "relay")
IOS = "packages/ios-app"
# The UIValidation test plan's targets, which scripts/tron-ios-test builds and runs. The Gateway E2E
# and profiling targets have their own lanes (scripts/ios-gateway-e2e-test, scripts/tron-profile ios).
IOS_TARGETS = {"UITests": "TronMobileUITests", "SwiftAppUITests": "TronSwiftAppUITests"}
# UIValidation journey classes that need a fixture only their harness provides; they run in its lane.
IOS_HARNESSED = {"RealGatewayPairAndChatUITests": "scripts/ios-gateway-e2e-test",
                 "TronMacTerminalUITests": "scripts/ios-mac-terminal-journey"}
NOT_DRIVEN = ("ios-lanes",)
# The real-UI journeys run, by exact selector, through the harness that owns them (its
# `ui_owned_journeys`), as `verify --batch`'s UI journey lane runs them all.
JOURNEY_CLASS = "RealGatewayPairAndChatUITests"
JOURNEY_HARNESS = "scripts/ios-gateway-e2e-test"
JOURNEY_LANES = 3
JOURNEY_LINE = re.compile(r"^Real-UI journey (\S+) completed in \d+s \(status (\d+)\); evidence: (\S+)$", re.M)
# Estimated test seconds per iOS runner process. A shard keeps the runner's unchanged 1200 s
# focused deadline even when every method takes twice its longest recorded time and the process
# spends IOS_LAUNCH_SECONDS launching. A method with no record counts a third of the budget, so
# unmeasured methods run three to a process.
IOS_DEADLINE_SECONDS = 1200
IOS_LAUNCH_SECONDS = 60
IOS_SHARD_SECONDS = (IOS_DEADLINE_SECONDS - IOS_LAUNCH_SECONDS) / 2
IOS_UNMEASURED_SECONDS = IOS_SHARD_SECONDS / 3
# Runner logs scripts/tron-ios-test keeps for every worktree and lane (its RESULTS_ROOT), and the
# line XCTest prints for each finished case.
IOS_RESULTS_ROOT = Path(os.environ.get("TRON_IOS_TEST_RESULTS_DIR") or Path.home() / "Library/Developer/Tron/ios/test-runs")
IOS_CASE_LINE = re.compile(rb"^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (?:passed|failed) \((\d+(?:\.\d+)?) seconds\)", re.M)
# An iPad-only UI test skips on the iPhone lane (`XCTSkipUnless(... == .pad ...)`), so
# its shard runs on this worktree's iPad lane with this device type instead.
IOS_PAD_GATE = re.compile(r"XCTSkipUnless\(\s*UIDevice\.current\.userInterfaceIdiom\s*==\s*\.pad\b")
IOS_PAD_DEVICE_TYPE = "iPad Pro 13-inch (M5)"


class VerifyError(Exception):
    pass


def git(*args: str) -> str:
    done = subprocess.run(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args], capture_output=True, text=True, errors="replace")
    if done.returncode:
        raise VerifyError(done.stderr.strip() or f"git {args[0]} failed")
    return done.stdout


def signal_group(group: int, signum: int) -> None:
    """Signal a process group this verifier started (same uid, no setuid lanes); a group that already
    ended is no error. macOS answers EPERM while every member has exited but its leader is not yet
    reaped, and ESRCH once it is; for an owned group no other EPERM cause applies."""
    try:
        os.killpg(group, signum)
    except (ProcessLookupError, PermissionError):
        pass


def install_hint(package: str) -> str:
    return f"prepare this worktree with: scripts/tron-node exec npm --prefix {package} ci --include=dev"


GATEWAY_INSTALL_HINT = install_hint(GATEWAY)


def require_install(package: str = GATEWAY) -> None:
    """A package's installed dependencies are exactly its lockfile's, by npm's own record of the install.

    Tests well beyond the Gateway import its packages (scripts/, tools/docs, tools/layers, tools/proof,
    tools/verify), so any test step needs them; the relay's own lane needs the relay's. A
    platform-optional package may be absent. The proof gate (python-here) runs compiled cores, which need the core's."""
    root, name, hint = ROOT / package, {GATEWAY: "Gateway", RELAY: "Relay", CORE: "Core"}[package], install_hint(package)
    try:
        wanted = json.loads((root / "package-lock.json").read_text())["packages"]
        installed = json.loads((root / "node_modules/.package-lock.json").read_text())["packages"]
    except (OSError, ValueError, KeyError) as error:
        raise VerifyError(f"{name} dependencies are not installed; {hint}") from error
    pinned = lambda entry: (entry.get("version"), entry.get("integrity"))  # noqa: E731
    differ = sorted(path for path in set(wanted) | set(installed) if path and (
        pinned(wanted[path]) != pinned(installed[path]) if path in wanted and path in installed
        else path in installed or not wanted[path].get("optional")))
    if differ:
        shown = ", ".join(differ[:5]) + (f" and {len(differ) - 5} more" if len(differ) > 5 else "")
        raise VerifyError(f"{name} dependencies differ from package-lock.json ({shown}); {hint}")


def require_gateway_compiler() -> None:
    """npm must resolve this checkout's pinned compiler, never a global tsc."""
    gateway = ROOT / GATEWAY
    hint = GATEWAY_INSTALL_HINT
    try:
        pinned = json.loads((gateway / "package.json").read_text())["devDependencies"]["typescript"]
        installed = json.loads((gateway / "node_modules/typescript/package.json").read_text())["version"]
    except (OSError, ValueError, KeyError) as error:
        raise VerifyError(f"Gateway TypeScript dependency is missing or unreadable; {hint}") from error
    if installed != pinned:
        raise VerifyError(f"Gateway TypeScript is stale (installed {installed}, pinned {pinned}); {hint}")
    compiler = gateway / "node_modules/typescript/bin/tsc"
    executable = gateway / "node_modules/.bin/tsc"
    if not compiler.is_file() or not os.access(executable, os.X_OK) or executable.resolve() != compiler.resolve():
        raise VerifyError(f"Gateway TypeScript local executable is missing or does not resolve to the pinned package; {hint}")


def is_lock(path: str) -> bool:
    return path.endswith(".lock.integration.test.ts") or path in NAMED_LOCKS or (
        path.startswith("packages/ios-app/UITests/Locks/") and path.endswith("Tests.swift"))


def is_test(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    if "/test-fixtures/" in path:
        return False  # recorders regenerate committed fixtures; never part of a verify run
    if path.startswith("packages/") and path.endswith(".swift"):
        return any(part in path.split("/") for part in ("UITests", "E2ETests", "ProfilingTests", "SwiftAppUITests", "Tests")) \
            and name.endswith("Tests.swift")
    return bool(re.search(r"\.test\.(ts|mjs)$", name)) or bool(re.match(r"test-.*\.(py|sh)$", name))


def is_doc(path: str) -> bool:
    """Markdown is prose: the documentation checks are its evidence, and no test reads it."""
    return path.endswith(".md")


def is_golden(path: str) -> bool:
    """Recorded lock output, read only by its module's locks."""
    return ".golden." in path.rsplit("/", 1)[-1] or "/Goldens/" in path


def nested_files() -> tuple[set, set]:
    listed = vitest_configs.listed_files(ROOT / GATEWAY)
    return tuple({f"{GATEWAY}/{entry}" for entry in listed[config]} for config in vitest_configs.LISTS)


# Python tests that read this Mac's own state run here, never on the mini: test-core.py verifies each block's review
# row against the reviewer's transcript in this Mac's Pi session store (tools/proof/README.md). Grow it only for
# tests that read this Mac's own state.
PYTHON_HERE = {"tools/proof/tests/test-core.py"}


def runner_of(path: str, nested: set, mac_terminal: set) -> str:
    if path.startswith(f"{GATEWAY}/src/"):
        return "mac-terminal" if path in mac_terminal else ("gateway-nested" if path in nested else "gateway")
    if path.endswith(".test.mjs"):
        return "node-gateway" if path.startswith(f"{GATEWAY}/") else "node"
    if path.endswith(".py"):
        return "python-here" if path in PYTHON_HERE else "python"
    if path.endswith(".sh"):
        return "shell"
    if path.startswith(f"{IOS}/"):
        if path.split("/")[2] not in IOS_TARGETS:
            return "ios-lanes"
        name = ios_class(path)
        return "ios-journeys" if name == JOURNEY_CLASS else "ios-lanes" if name in IOS_HARNESSED else "ios"
    if path.startswith(f"{MAC}/") and path.endswith(".swift"):
        return "mac"
    if path.startswith(f"{RELAY}/"):
        return "relay"
    raise VerifyError(f"no runner for test {path}")


def ios_class(path: str) -> str | None:
    """The XCTestCase class one iOS test file runs as: the class it is named for, else the class it extends."""
    stem, text = Path(path).stem, (ROOT / path).read_text()
    if re.search(rf"\bclass {re.escape(stem)}\b", text):
        return stem
    extended = re.search(r"^extension (\w+Tests)\b", text, re.M)
    return extended.group(1) if extended else None


def owned_journeys() -> list[str]:
    """The harness's `ui_owned_journeys`: the only selectors its `run-ui` accepts."""
    try:
        text = (ROOT / JOURNEY_HARNESS).read_text()
    except OSError as error:
        raise VerifyError(f"the real-UI journeys' harness is unreadable: {error}") from error
    block = re.search(r"^ui_owned_journeys=\((.*?)^\)", text, re.S | re.M)
    if block is None:
        raise VerifyError(f"{JOURNEY_HARNESS} declares no ui_owned_journeys")
    return re.findall(r"""['"]([\w/]+)['"]""", block.group(1))


def journey_selectors(paths: list[str]) -> list[str]:
    """The owned journeys a change reaches: the test methods a changed extension file declares, or,
    for the class's own file or an extension declaring no test (shared fixture and helpers), every
    owned journey."""
    owned = owned_journeys() if paths else []
    selected: set[str] = set()
    for path in paths:
        if path.split("/")[2] != "UITests":
            raise VerifyError(f"{path}: {JOURNEY_CLASS} journeys live in {IOS}/UITests ({IOS_TARGETS['UITests']})")
        methods = re.findall(r"func (test\w+)\s*\(", (ROOT / path).read_text())
        if Path(path).stem == JOURNEY_CLASS or not methods:
            selected.update(owned)
            continue
        for method in methods:
            selector = f"{IOS_TARGETS['UITests']}/{JOURNEY_CLASS}/{method}"
            if selector not in owned:
                raise VerifyError(f"{path}: {selector} is not a journey {JOURNEY_HARNESS} run-ui owns")
            selected.add(selector)
    return sorted(selected)


def journey_evidence(output: str, selectors: list[str], sha: str) -> tuple[list[dict], list[str], list[str]]:
    """Each journey's report.json the harness wrote, checked against its report.sha256 and this
    commit's clean source; returns the reports, the failed journeys and the selectors with no
    passing report for this commit."""
    reports, failed = [], []
    passing = set()
    for journey, status, directory in JOURNEY_LINE.findall(output):
        path = Path(directory) / "report.json"
        try:
            data = path.read_bytes()
            report = json.loads(data)
            recorded = (Path(directory) / "report.sha256").read_text().split()[0]
        except (OSError, ValueError, IndexError):
            failed.append(journey)
            continue
        digest = hashlib.sha256(data).hexdigest()
        source = report.get("source") or {}
        reports.append({"journey": journey, "status": report.get("journey_status"), "report": str(path), "sha256": digest,
                        "revision": source.get("revision"), "dirty": source.get("dirty")})
        if int(status) or report.get("journey_status") != 0:
            failed.append(journey)
        elif (digest == recorded and report.get("journey") == journey and report.get("evidence_complete") is True
              and source.get("revision") == sha and source.get("dirty") is False):
            passing.add(journey)
    return reports, failed, [selector for selector in selectors if selector not in passing]


def ios_selectors(paths: list[str]) -> list[str]:
    """`--only-testing` owners of UIValidation test files: target/class, once per class."""
    owners = []
    for path in paths:
        name = ios_class(path)
        if name is None:
            raise VerifyError(f"{path} declares or extends no XCTestCase class; name the file for its class")
        owner = f"{IOS_TARGETS[path.split('/')[2]]}/{name}"
        owners += [] if owner in owners else [owner]
    return owners


def ios_test_methods(owner: str) -> tuple[list[str], set[str]]:
    """`Target/Class/testMethod` owners XCTest runs for `Target/Class`: the no-argument, non-private
    `test` methods declared in the class or its top-level extensions in that target's sources, and
    the subset that is iPad-only (the method, or the class's setUp, skips unless on an iPad).
    Fails closed: a test-shaped method whose enclosing top-level type cannot be read makes the
    class run whole (an empty result) rather than silently dropping a test."""
    target, name = owner.split("/")
    folder = next(path for path, candidate in IOS_TARGETS.items() if candidate == target)
    top_level = re.compile(r"^(?:(?:final|public|open|private|fileprivate|internal|@\w+(?:\([^)]*\))?)\s+)*"
                           r"(?:class|struct|enum|actor|extension|protocol)\s+(\w+)")
    method = re.compile(r"^\s+(?:@\w+(?:\([^)]*\))?\s+)*(?:override\s+)?func\s+(test\w*)\(\)")
    shaped = re.compile(r"\bfunc\s+(test\w*)\s*\(\s*\)")
    hidden = re.compile(r"\b(?:private|fileprivate|static|class)\s+func\b")
    member_line = re.compile(r"^\s+(?:(?:@\w+(?:\([^)]*\))?|override|private|fileprivate|public|open|internal|static|class|nonisolated)\s+)*func\s+(\w+)")
    found: list[str] = []
    pad: set[str] = set()
    bodies: dict[str, str] = {}
    class_pad = False
    unplaced = False
    for source in sorted((ROOT / IOS / folder).rglob("*.swift")):
        text = source.read_text(errors="replace")
        if not re.search(rf"\b(?:class|extension)\s+{re.escape(name)}\b", text):
            continue
        scope: str | None = None
        member: str | None = None
        for line in text.splitlines():
            if scope == name and (declared_member := member_line.match(line)):
                member = declared_member.group(1)
            if scope == name and member:
                bodies[member] = bodies.get(member, "") + line + "\n"
            if scope == name and member and IOS_PAD_GATE.search(line):
                class_pad = class_pad or member in ("setUp", "setUpWithError")
                pad.add(member)
            # A top-level line opens a type's scope, or an unknown one; a bare attribute line does not.
            if line[:1] not in ("", " ", "\t", "}", "/", "#") and (
                    line[:1] != "@" or re.search(r"\b(?:class|struct|enum|actor|extension|protocol|func|var|let)\b", line)):
                declared = top_level.match(line)
                scope = declared.group(1) if declared else None
                member = None
            elif scope == name and (match := method.match(line)):
                found += [] if match.group(1) in found else [match.group(1)]
            elif scope == name and shaped.search(line) and not hidden.search(line):
                unplaced = True  # a test spelled in a way the reader does not select
            elif scope is None and shaped.search(line) and not hidden.search(line):
                unplaced = True
    if unplaced:
        return [], set()
    # A test that calls a gated helper of its class is iPad-only too (one call level).
    helpers = [helper for helper in pad if helper not in found]
    gated = {test for test in found if class_pad or test in pad
             or any(re.search(rf"\b{re.escape(helper)}\(", bodies.get(test, "")) for helper in helpers)}
    return [f"{owner}/{test}" for test in found], {f"{owner}/{test}" for test in gated}


class IosShard(list):
    """Selectors one runner process executes; `pad` shards run on the iPad lane. `seconds` is
    the shard's estimate, which orders the queue (longest first)."""
    pad = False
    seconds = 0.0


def ios_method_seconds(results: Path = IOS_RESULTS_ROOT) -> dict[str, float]:
    """`Target/Class/testMethod` to the longest it took in any runner log under `results`. An
    estimate for packing only: it never selects, skips or judges a test."""
    longest: dict[str, float] = {}
    try:
        entries = list(os.scandir(results))
    except OSError:
        return longest
    for entry in entries:
        try:
            text = (Path(entry.path) / "test.log").read_bytes()
        except OSError:
            continue
        for target, owner, method, seconds in IOS_CASE_LINE.findall(text):
            key = f"{target.decode()}/{owner.decode()}/{method.decode()}"
            longest[key] = max(longest.get(key, 0.0), float(seconds))
    return longest


def ios_shards(selectors: list[str], seconds: dict[str, float]) -> list[IosShard]:
    """The selected classes' test methods in selection order, iPhone methods first, then iPad-only
    methods in their own shards, cut into consecutive runs whose estimates (`seconds`, else
    IOS_UNMEASURED_SECONDS) fit IOS_SHARD_SECONDS; a method estimated above it runs alone. Classes
    whose methods cannot be read run whole, together, in one final shard."""
    methods, pad_methods, whole = [], [], []
    for owner in selectors:
        found, pad = ios_test_methods(owner)
        methods += [method for method in found if method not in pad]
        pad_methods += [method for method in found if method in pad]
        whole += [] if found else [owner]
    shards: list[IosShard] = []
    for group, is_pad in ((methods, False), (pad_methods, True)):
        shard = None
        for method in group:
            estimate = seconds.get(method, IOS_UNMEASURED_SECONDS)
            if shard is None or (shard and shard.seconds + estimate > IOS_SHARD_SECONDS):
                shard = IosShard()
                shard.pad = is_pad
                shards.append(shard)
            shard.append(method)
            shard.seconds += estimate
    if whole:
        shards.append(IosShard(whole))
        shards[-1].seconds = IOS_SHARD_SECONDS
    return shards


def ios_lane_name(kind: str) -> str:
    """One of this worktree's own verify lanes, so concurrent worktrees never share one lease."""
    return f"verify-{kind}-" + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]


def ios_pad_lane() -> str:
    return ios_lane_name("ipad")


def ios_phone_lanes() -> list[str | None]:
    """The iPhone lanes shards run on at once: the worktree's own lane (None), then one
    verify lane per further host slot (scripts/ios-test-lock.py owns the slot count)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("verify_ios_lock", ROOT / "scripts/ios-test-lock.py")
    locker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(locker)
    return [None] + [ios_lane_name(f"iphone{index}") for index in range(2, locker.HOST_SLOTS + 1)]


def ios_index_stale() -> str | None:
    """Why this commit has no fresh iOS index (the stamp scripts/tron-ios-test build writes), or None."""
    try:
        products = swift_index.fresh_store(ROOT).parent.parent
    except swift_index.IndexError_ as error:
        return str(error)
    # scripts/tron-ios-test run needs the products too, not only the index.
    return None if (products / "Build" / "Products").is_dir() else f"no test products in {products}"


def ios_count(output: str) -> int:
    """Passing tests in the XCTest summary of the run scripts/tron-ios-test reports as complete."""
    found = re.findall(r"^iOS test run complete: (.+)$", output, re.M)
    try:
        return json.loads((Path(found[-1]) / "summary.json").read_text()).get("passedTests", 0) if found else 0
    except (OSError, ValueError):
        return 0  # no readable summary: no evidence


def ios_failures(output: str) -> list[str]:
    found = re.findall(r"^iOS test run failed with status \d+: (.+)$", output, re.M)
    try:
        summary = json.loads((Path(found[-1]) / "summary.json").read_text()) if found else {}
    except (OSError, ValueError):
        return []
    return [f"{item.get('testIdentifierString') or item.get('testName')}: {item.get('failureText', '').splitlines()[0][:200] if item.get('failureText') else ''}"
            for item in summary.get("testFailures", [])]


# ---------------------------------------------------------------------------- selection

def declared_files(command: str, tracked: list[str]) -> set[str]:
    """Manifest commands select tracked inputs to existing runners, never a shell command."""
    try:
        words = shlex.split(command)
    except ValueError as error:
        raise VerifyError(f"invalid verify declaration {command!r}: {error}") from error
    prefix, arguments = words[:3], words[3:]
    files: set[str] = set()
    if prefix == ["scripts/tron", "test", "tooling"] and arguments:
        if all(path.endswith(".py") and (path.startswith(("scripts/test-", "scripts/verify-"))
                                         or re.fullmatch(r"tools/[^/]+/tests/test-[^/]+", path)) for path in arguments):
            files = set(arguments)
    elif prefix == ["scripts/tron", "test", "gateway"] and arguments:
        if all(path.endswith(".test.mjs") or (path.startswith("src/") and path.endswith(".test.ts")) for path in arguments):
            files = {f"{GATEWAY}/{path}" for path in arguments}
    elif prefix == ["scripts/tron", "test", "mac"]:
        classes = set(arguments)
        files = {path for path in tracked if path.startswith(f"{MAC}/") and path.endswith(".swift") and is_test(path)
                 and (not classes or Path(path).stem in classes)}
        if classes - {Path(path).stem for path in files}:
            raise VerifyError(f"unknown Mac test class in verify declaration: {command!r}")
    elif prefix == ["scripts/tron", "test", "ios"] and arguments[:1] == ["run"]:
        pairs = arguments[1:]
        if pairs and len(pairs) % 2 == 0 and all(flag == "--only-testing" for flag in pairs[::2]):
            for selector in pairs[1::2]:
                matching = {path for path in tracked if path.startswith(f"{IOS}/") and is_test(path)
                            and path.split("/")[2] in IOS_TARGETS
                            and (name := ios_class(path)) is not None
                            and selector == f"{IOS_TARGETS[path.split('/')[2]]}/{name}"}
                if not matching:
                    raise VerifyError(f"unknown UI test class in verify declaration: {selector!r}")
                files |= matching
    if not files or not files <= set(tracked):
        raise VerifyError(f"unsupported verify declaration or untracked test input: {command!r}; see tools/verify/README.md")
    return files


def changed_paths(base: str, working: bool = False) -> list[str]:
    # Both rename endpoints matter; NUL records preserve whitespace and non-ASCII names.
    names = set()
    ranges = [[f"{base}...HEAD"]] + ([["HEAD"]] if working else [])
    for comparison in ranges:
        fields = git("diff", "--name-status", "-z", "-M", *comparison).split("\0")
        i = 0
        while i < len(fields) and fields[i]:
            width = 2 if fields[i][0] in "RC" else 1
            names.update(fields[i + 1:i + 1 + width])
            i += 1 + width
    if working:
        names.update(filter(None, git("ls-files", "--others", "--exclude-standard", "-z").split("\0")))
    return sorted(names)


def is_test_code(path: str) -> bool:
    """Test files and the fixtures, support and goldens that exist only for them."""
    parts = path.split("/")
    return is_test(path) or is_golden(path) or any(part in parts for part in ("test-support", "test-fixtures", "Fixtures", "tests", "locks"))


COMPAT_WORDS = re.compile(r"\b(legacy|compat|compatibility|shim|deprecated)\b", re.IGNORECASE)


def test_stem(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    return name[:-len("Tests.swift")] if name.endswith("Tests.swift") else re.sub(r"^test-", "", name).split(".")[0]


def delta(base: str) -> dict:
    """What the change adds and deletes, split into source and test code. A new test file
    whose stem an existing test file in the same directory already carries is listed with
    that owner: the reviewer decides whether the proof belonged in it (test-oracles.md)."""
    counts = {"source": [0, 0], "tests": [0, 0], "docs": [0, 0]}
    for line in git("diff", "--numstat", "-M", f"{base}..HEAD").splitlines():
        added, removed, path = line.split("\t", 2)
        if added == "-":
            continue  # binary
        path = re.sub(r"\{[^{}]* => ([^{}]*)\}", r"\1", path).split(" => ")[-1].replace("//", "/")
        side = counts["docs" if is_doc(path) else "tests" if is_test_code(path) else "source"]
        side[0] += int(added)
        side[1] += int(removed)
    status = git("diff", "--name-status", "-M", f"{base}..HEAD").splitlines()
    rows = [row.split("\t") for row in status]
    # A rename into a new test path is reviewed like an addition; its source left as a deletion.
    added = [fields[-1] for fields in rows if fields[0][0] in "AR" and is_test(fields[-1])
             and not (fields[0][0] == "R" and is_test(fields[1]) and test_stem(fields[1]) == test_stem(fields[-1]))]
    deleted = [fields[1] for fields in rows if fields[0][0] in "DR" and is_test(fields[1])
               and not (fields[0][0] == "R" and is_test(fields[-1]) and test_stem(fields[1]) == test_stem(fields[-1]))]
    beside = {}
    base_tests = [name for name in git("ls-tree", "-r", "--name-only", base).splitlines() if is_test(name)] if added else []
    for path in added:
        owners = [name for name in base_tests if name != path and name.rpartition("/")[0] == path.rpartition("/")[0]
                  and test_stem(name) == test_stem(path)]
        if owners:
            beside[path] = sorted(owners)
    # Added source lines that name compatibility machinery, which AGENTS.md forbids.
    bridges, path = [], None
    for line in git("diff", "-U0", "-M", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", f"{base}..HEAD").splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            path = path if path and not is_test_code(path) and not is_doc(path) else None
        elif path and line.startswith("+") and COMPAT_WORDS.search(line):
            bridges.append(f"{path}: {line[1:].strip()[:160]}")
    return {"sourceLines": {"added": counts["source"][0], "removed": counts["source"][1]},
            "testLines": {"added": counts["tests"][0], "removed": counts["tests"][1]},
            "docLines": {"added": counts["docs"][0], "removed": counts["docs"][1]},
            "addedTestFiles": added, "deletedTestFiles": deleted, "besideExistingOwner": beside, "compatAdditions": bridges}


def golden_readers(goldens: list[str], tests: list[str]) -> set[str]:
    """The locks a golden change reruns. A Gateway E2E golden `<dir>/locks/<name>.golden.json` is read
    only by the lock in `<dir>` naming it through `lockPaths(import.meta.url, "<name>")`, or through a
    computed argument when the lock spells `"<name>"`; any other golden reruns every lock its module owns.
    A deleted golden no lock names any more needs none: the lock that dropped it changed and is selected as a changed test."""
    locks = [path for path in tests if is_lock(path)]
    readers: set[str] = set()
    for golden in goldens:
        if not golden.startswith(f"{GATEWAY}/src/e2e/"):
            readers |= set(locks)
            continue
        name = Path(golden).name.removesuffix(".golden.json")
        directory = str(Path(golden).parent.parent)
        found = set()
        for lock in (path for path in locks if str(Path(path).parent) == directory):
            source = (ROOT / lock).read_text(errors="replace")
            arguments = re.findall(r"lockPaths\(import\.meta\.url,\s*([\w.$]+|\"[^\"]+\"|'[^']+')\s*\)", source)
            names = {argument[1:-1] for argument in arguments if argument[0] in "\"'"}
            computed = [argument for argument in arguments if argument[0] not in "\"'"]
            # A computed name (a constant or a trace field) reads this golden when the
            # lock spells the name as a string anywhere in its source.
            if computed and re.search(rf"['\"]{re.escape(name)}['\"]", source):
                names.add(name)
            if name in names:
                found.add(lock)
        if not found and not (ROOT / golden).exists():
            continue
        if not found:
            raise VerifyError(f"no lock beside {golden} reads it through lockPaths(import.meta.url, {name!r})")
        readers |= found
    return readers


PYTHON_IMPORT = re.compile(r"^[ \t]*(?:from[ \t]+([A-Za-z_]\w*)[\w.]*[ \t]+import\b|import[ \t]+([^#\n]+))", re.M)
JS_IMPORT = re.compile(r"""(?:\bfrom|\bimport)\s*\(?\s*["'](\.{1,2}/[^"']+)["']""")


def importers(changed: list[str], tracked: list[str]) -> dict[str, set[str]]:
    """Untyped code files that import a changed file, by importer: Python by module name (or by the
    path it hands importlib), JavaScript by relative specifier. A typed importer is left to its
    compiler, which already checks the shapes it uses across modules."""
    names: dict[str, set[str]] = {}
    for path in changed:
        if path.endswith(".py") and Path(path).stem.isidentifier():
            names.setdefault(Path(path).stem, set()).add(path)
    python_paths = [path for path in changed if path.endswith(".py")]
    targets = set(changed)
    found: dict[str, set[str]] = {}
    for path in tracked:
        file = ROOT / path
        python = path.endswith(".py")
        if not (python or path.endswith((".mjs", ".js", ".cjs"))):
            if "." in Path(path).name or not path.startswith(("scripts/", "tools/")):
                continue
            try:
                with file.open("rb") as stream:
                    python = b"python" in stream.readline()
            except OSError:
                continue
            if not python:
                continue
        try:
            source = file.read_text(errors="replace")
        except OSError:
            continue
        hits = set()
        if python:
            for first, listed in PYTHON_IMPORT.findall(source):
                for name in [first] if first else [part.split()[0].split(".")[0] for part in listed.split(",") if part.split()]:
                    hits |= names.get(name, set())
            if "spec_from_file_location" in source:
                hits |= {target for target in python_paths if target in source}
        else:
            for specifier in JS_IMPORT.findall(source):
                resolved = os.path.normpath(str(Path(path).parent / specifier))
                candidates = {resolved, resolved + ".js", resolved + ".mjs", resolved + ".ts", f"{resolved}/index.js"}
                if resolved.endswith(".js"):
                    candidates.add(resolved[:-3] + ".ts")
                hits |= candidates & targets
        hits.discard(path)
        if hits:
            found[path] = hits
    return found


def select(mode: str, target: str | None, base: str, modules: dict, tracked: list, paths: list | None = None) -> dict:
    """The tests a run selects; `paths` stands in for the changed paths (the mutation sampler's one file)."""
    # A serial-runner entry naming no tracked file matches nothing, so its runner would pass silently.
    stale = sorted(set().union(*nested_files()) - set(tracked))
    if stale:
        raise VerifyError(f"serial runner config lists untracked {', '.join(stale)}; remove the entry")
    owner = {path: key for key, module in modules.items() for path in module["owned"]}
    tests = [path for path in tracked if is_test(path)]
    locks = sorted(path for path in tests if is_lock(path))
    reasons: list[str] = []
    declared: set[str] = set()
    declared_tests: set[str] = set()
    selected: set[str] = set()
    narrow: set[str] = set()
    batch_tests: set[str] = set()
    deferred: set[str] = set()
    full_reasons: list[str] = []
    if mode == "all":
        selected |= set(locks)
        reasons.append(f"--all: every lock ({len(locks)} files)")
        touched, chosen = ["(all)"], set()
        declared = set(modules)
        # Include all serial files selected by the covered diff, including changed
        # tests run before landing: later integration can affect those cases too.
        changed = select("changed", None, base, modules, tracked)
        serial = set(changed["deferredTests"]) | (set(changed["tests"]) & nested_files()[0])
        selected |= serial
        if serial:
            reasons.append(f"covered diff: {len(serial)} serial test file(s)")
    elif mode in ("module", "update-locks"):
        if target not in modules:
            raise VerifyError(f"no module {target!r}; see scripts/tron ownership --modules")
        chosen = {target}
        owned = [path for path in modules[target]["owned"] if is_test(path)]
        selected |= set(path for path in owned if mode == "module" or is_lock(path))
        reasons.append(f"--{mode} {target}: {'its owned tests' if mode == 'module' else 'its locks'} ({len(selected)} files)")
        touched = sorted(modules[target]["owned"])
    else:
        touched = changed_paths(base) if paths is None else sorted(paths)
        # A deleted documentation asset still belongs to its base owner.
        gone = [path for path in touched if path not in tracked]
        if gone:
            base_modules = ownership.check(base)[0]["modules"]
            owner = {**{path: key for key, module in base_modules.items() for path in module["owned"]}, **owner}
        docs = [path for path in touched if is_doc(path) or (owner.get(path) == "repo/docs" and not path.endswith(".module.json"))]
        if docs:
            reasons.append(f"{len(docs)} documentation file(s): the documentation checks cover them; they select no test")
        code = [path for path in touched if path not in docs]
        unowned = [path for path in code if path not in owner and path in tracked]
        # A deleted or renamed-away path is owned as of the base revision.
        gone = [path for path in code if path not in tracked]
        if gone:
            base_modules = ownership.check(base)[0]["modules"]
            owner = {**{path: key for key, module in base_modules.items() for path in module["owned"]}, **owner}
            unowned += [path for path in gone if path not in owner]
        changes: dict[str, list[str]] = {}
        for path in code:
            if path in owner:
                changes.setdefault(owner[path], []).append(path)
        chosen = set(changes)
        # A module whose change is only its own tests and goldens runs those tests and, for a golden, its
        # locks: no other code reads a test file or a golden, so nothing depending on the module changed.
        narrow = {key for key, paths in changes.items() if all(is_test(path) or is_golden(path) for path in paths)
                  and (not any(is_golden(path) for path in paths) or any(is_lock(path) for path in modules.get(key, {"owned": []})["owned"]))}
        for key in sorted(chosen):
            owned = [path for path in modules.get(key, {"owned": []})["owned"] if is_test(path)]
            if key in narrow:
                goldens = any(is_golden(path) for path in changes[key])
                readers = golden_readers([path for path in changes[key] if is_golden(path)], owned)
                owned = [path for path in owned if path in changes[key] or (goldens and is_lock(path) and path in readers)]
                reasons.append(f"{key}: changes only its tests{' and goldens' if goldens else ''}; those {len(owned)} test file(s)")
            else:
                reasons.append(f"{key}: owns a changed path; its {len(owned)} owned test file(s)")
            selected |= set(owned)
        # A changed source file's untyped importers in other modules run their tests too: no compiler
        # checks the shape they read (#2364). An importing test file runs alone; importing source runs
        # its module's owned tests, a deleted file's included. One hop: the importer's own exports did not change.
        sources = [path for key in changes if key not in narrow for path in changes[key] if not is_test(path)]
        consumers: dict[str, set[str]] = {}
        for importer, hits in importers(sources, tracked).items():
            key = owner.get(importer)
            if key is None or all(owner.get(hit) == key for hit in hits):
                continue
            if is_test(importer):
                if importer not in selected:
                    selected.add(importer)
                    reasons.append(f"{importer}: imports changed {', '.join(sorted(hits))}")
            elif key not in chosen:
                consumers.setdefault(key, set()).update(hit for hit in hits if owner.get(hit) != key)
        for key in sorted(consumers):
            owned = [path for path in modules[key]["owned"] if is_test(path)]
            selected |= set(owned)
            reasons.append(f"{key}: imports changed {', '.join(sorted(consumers[key]))}; its {len(owned)} owned test file(s)")
    if mode in ("changed", "module"):
        # A change is gated by its own modules' tests (docs/PRINCIPLES.md P1). The one consumer
        # added is a module whose dynamic edge names a selected one (today only the iOS UI
        # tests' spawn edges to the hosted app): its locks are that module's rendered tests. `dependsOn` consumers'
        # locks run in the batch.
        sources = chosen - narrow
        spawners = {key for key, module in modules.items() if key not in sources
                    and set(module.get("dynamicTargets", [])) & sources}
        for key in sorted(spawners):
            spawned = [path for path in modules[key]["owned"] if is_test(path) and is_lock(path)]
            selected |= set(spawned)
            reasons.append(f"{key}: launches a selected module; its {len(spawned)} lock file(s)")
        chosen |= spawners
        # Risk belongs to the changed producer; the locks a full tier adds run in the next batch.
        if mode == "changed":
            for key in sorted(set(changes) - narrow):
                module = modules.get(key)
                if module is None:
                    full_reasons.append(f"deleted module {key}")
                    continue
                risk = module["riskClass"]
                if module["layer"] in WIDENING_LAYERS or key in WIDENING_MODULES or set(risk) - {"ios-ui"}:
                    full_reasons.append(f"{key} ({module['layer']})" + (f" risk={','.join(risk)}" if risk else ""))
            full_reasons += [f"unowned {path}" for path in unowned]
            for path in touched:
                filename = Path(path).name
                if path.endswith(".module.json") or filename in {
                    "package.json", "package-lock.json", "project.yml", ".node-version", "layer-baseline.json", "settings-schema.ts"
                } or filename.startswith("tsconfig"):
                    full_reasons.append(f"graph/toolchain/schema input {path}")
            if full_reasons:
                batch_tests |= set(locks)
                reasons.append(f"full batch required; widened to every lock ({len(locks)} files) in batch: {', '.join(full_reasons)}")
        # Retired owners still seed full risk above, but only live
        # modules own verification commands that can execute now.
        declared |= (chosen - narrow) & modules.keys()
    for key in sorted(declared):
        external = set()
        for command in modules[key].get("verify", []):
            external |= declared_files(command, tracked)
        if external:
            selected |= external
            declared_tests |= external
            reasons.append(f"{key}: declared verification ({len(external)} test file(s))")
    if mode == "changed":
        nested, _ = nested_files()
        golden_owners = {owner[path] for path in touched if is_golden(path) and path in owner}
        immediate = {path for path in selected if owner.get(path) in narrow
                     or (is_lock(path) and owner.get(path) in golden_owners)}
        deferred = (selected & nested) - set(touched) - immediate - declared_tests
        selected -= deferred
        if deferred:
            batch_tests |= deferred
            full_reasons.append(f"{len(deferred)} unchanged serial nested test file(s)")
            reasons.append(f"deferred to full batch: {len(deferred)} unchanged serial nested test file(s); changed tests still run now")
    if full_reasons:
        batch_tests |= set(locks) | (selected & nested_files()[0])
    if batch_tests or full_reasons:
        for module in modules.values():
            for command in module.get("verify", []):
                batch_tests |= declared_files(command, tracked)
    docs_only = mode == "changed" and len(docs) == len(touched)
    # Generated doc blocks are built from Markdown, manifests and Gateway sources (tools/docs/README.md).
    doc_inputs = mode == "all" or any(is_doc(path) or path.endswith(".module.json") for path in touched)
    tier = "none" if docs_only else "full" if mode == "all" or full_reasons else "partial"
    return {"mode": mode, "base": base, "modules": sorted(chosen), "touched": len(touched), "paths": touched,
            "tier": tier, "fullReasons": full_reasons, "batchTests": sorted(batch_tests), "deferredTests": sorted(deferred), "reasons": reasons,
            "tests": sorted(selected), "docsOnly": docs_only, "docInputs": doc_inputs}


# ---------------------------------------------------------------------------- steps

class Launched:
    def __init__(self, label: str, result: dict, process: subprocess.Popen, log: Path, started: float):
        self.label, self.result, self.process, self.log, self.started = label, result, process, log, started


class Run:
    def __init__(self, sha: str, total: int):
        self.sha, self.total, self.index, self.steps = sha, total, 0, []
        self.live: list[Launched] = []  # launched step processes not yet settled
        self.logs = ROOT / "test-results" / "verify" / sha
        self.logs.mkdir(parents=True, exist_ok=True)
        self.on_update = lambda: None

    def step(self, name: str, command: list[str] | str, cwd: Path = ROOT, count=None, env: dict | None = None,
             accept=(0,)) -> dict:
        self.index += 1
        try:
            # Inside the try: a signal held during launch arrives as it returns.
            launched = self.launch(self.index, name, command, cwd, env)
            code = launched.process.wait()
        except KeyboardInterrupt:
            self.stop(list(self.live))
            raise
        return self.settle(launched, code, count, accept)

    def launch(self, index: int, name: str, command: list[str] | str, cwd: Path = ROOT, env: dict | None = None,
               note: str = "") -> "Launched":
        """Start one step's process in its own session, its output in the step's live log."""
        log = self.logs / f"{index:02d}-{re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')}.log"
        label = f"[{index}/{self.total}] {name}"
        print(f"{label} …{note} (live log: {log.relative_to(ROOT)})", flush=True)
        result = {"name": name, "status": "running", "command": command, "cwd": str(cwd.relative_to(ROOT)),
                  "tests": None, "seconds": 0, "log": str(log.relative_to(ROOT))}
        self.steps.append(result)
        self.on_update()
        # Signals wait until the process is recorded as live, so an interrupt always finds it to
        # stop; the child starts with them unblocked, so it can be stopped.
        stopping = {signal.SIGINT, signal.SIGTERM}
        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, stopping)
        try:
            with log.open("w") as stream:
                process = subprocess.Popen(command, cwd=cwd, shell=isinstance(command, str), stdout=stream,
                                           stderr=subprocess.STDOUT, env={**os.environ, **(env or {})}, start_new_session=True,
                                           preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, stopping))
            launched = Launched(label, result, process, log, time.time())
            self.live.append(launched)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
        return launched

    def stop(self, launched: list["Launched"]) -> None:
        """Stop and join the owned process groups (SIGTERM, then SIGKILL after 30 s); each is interrupted."""
        for item in launched:
            signal_group(item.process.pid, signal.SIGTERM)
        deadline = time.time() + 30
        for item in launched:
            try:
                item.process.wait(timeout=max(0.0, deadline - time.time()))
            except subprocess.TimeoutExpired:
                signal_group(item.process.pid, signal.SIGKILL)
                item.process.wait()
            self.settle(item, 130, None, (0,), interrupted=True)

    def settle(self, launched: "Launched", code: int, count, accept, interrupted: bool = False) -> dict:
        result, label = launched.result, launched.label
        if launched in self.live:
            self.live.remove(launched)
        output = launched.log.read_text(errors="replace")
        ok = code in accept and not interrupted
        tests = count(output) if count and ok else None
        status = "interrupted" if interrupted else "ok" if ok else "failed"
        seconds = round(time.time() - launched.started, 1)
        result.update(status=status, exit=code, tests=tests, seconds=seconds)
        self.on_update()
        print(f"{label} {status.upper()} in {seconds}s" + (f" — {tests} passing test(s)" if tests is not None else ""), flush=True)
        if status != "ok":
            tail = output.strip().splitlines()[-25:]
            print("\n".join(f"    {line}" for line in tail), flush=True)
            print(f"    full log: {result['log']}", flush=True)
        return result

    def withdraw(self, launched: "Launched") -> None:
        """Forget a launch that admitted no work (an opportunistic shard refused a slot); its retry reuses the log."""
        self.live.remove(launched)
        self.steps.remove(launched.result)
        self.on_update()

    def reused(self, name: str, detail: str, command: list[str]) -> None:
        """A step whose evidence already exists for this commit; it compares equal to running it (exit 0)."""
        self.index += 1
        print(f"[{self.index}/{self.total}] {name} OK — {detail}", flush=True)
        self.steps.append({"name": name, "status": "ok", "exit": 0, "tests": None, "seconds": 0, "detail": detail,
                           "command": command, "cwd": "."})
        self.on_update()

    def skipped(self, name: str, reason: str, index: int | None = None) -> None:
        if index is None:
            self.index += 1
        print(f"[{index or self.index}/{self.total}] {name} SKIPPED — {reason}", flush=True)
        self.steps.append({"name": name, "status": "skipped", "reason": reason, "tests": None, "seconds": 0})
        self.on_update()


def comparable_steps(steps: list[dict]) -> list[dict]:
    """Step outcomes without timing. The iOS shards count as one step: how methods are packed
    (from this Mac's timing history) and which lane and slot wait ran each vary between runs."""
    kept: list[dict] = []
    shards = [step for step in steps if step["name"] == "tests: ios" or step["name"].startswith("tests: ios ")]
    for step in steps:
        if not any(step is shard for shard in shards):
            kept.append({key: value for key, value in step.items() if key not in ("seconds", "log", "detail")})
        elif step is shards[0]:
            statuses = {shard["status"] for shard in shards}
            kept.append({"name": "tests: ios", "tests": sum(shard.get("tests") or 0 for shard in shards),
                         "status": next((status for status in ("interrupted", "failed", "deferred", "running", "skipped")
                                         if status in statuses), "ok"),
                         "failedTests": sorted(name for shard in shards for name in shard.get("failedTests", [])),
                         "deferredTests": sorted({name for shard in shards for name in shard.get("deferredTests", [])})})
    return kept


def failure_digest(messages: list[str]) -> str:
    # Only the checkout prefix varies between base/candidate. Preserve messages,
    # stack locations and temporary paths: a changed failure must not be waived.
    return hashlib.sha256(json.dumps([message.replace(str(ROOT), "<repo>") for message in messages], ensure_ascii=False).encode()).hexdigest()


def gateway_failures(report: Path, output: str) -> tuple[dict[str, str], bool]:
    """Missing reports and suite/runtime errors never become an exact-case waiver."""
    try:
        data = json.loads(report.read_text())
        # Pinned Vitest JSON omits global unhandled errors; its diagnostic is
        # therefore also a refusal signal, never another waiver source.
        failed, suite_error, count = {}, bool(re.search(r"unhandled (?:errors?|rejection)|uncaught exception|failed suites?", output, re.I)), 0
        for suite in data["testResults"]:
            cases = [test for test in suite["assertionResults"] if test["status"] == "failed"]
            file = Path(suite["name"]).resolve().relative_to(ROOT)
            for test in cases:
                messages = test["failureMessages"]
                if not isinstance(messages, list) or not messages or not all(isinstance(message, str) and message for message in messages):
                    return {}, False
                failed[f"{file.as_posix()}::{test['fullName']}"] = failure_digest(messages)
                count += 1
            suite_error |= bool(suite.get("message") or suite.get("testExecError") or suite.get("errors")) or (suite.get("status") == "failed" and not cases)
        complete = bool(failed) and len(failed) == count == data["numFailedTests"] and not suite_error and not data.get("numRuntimeErrorTestSuites") and not data.get("unhandledErrors")
        return failed, complete
    except (OSError, ValueError, KeyError, TypeError):
        return {}, False


def case_outcomes(report: Path) -> tuple[list[dict], bool]:
    """Privacy-safe observations from this invocation's actual Vitest report."""
    try:
        data = json.loads(report.read_text())
        failed, failure_complete = gateway_failures(report, '')
        cases = []
        for suite in data['testResults']:
            file = Path(suite['name']).resolve().relative_to(ROOT).as_posix()
            for test in suite['assertionResults']:
                if test['status'] not in ('passed', 'failed'):
                    continue
                case = {'caseDigest': hashlib.sha256(f"{file}::{test['fullName']}".encode()).hexdigest(),
                        'status': test['status']}
                if test['status'] == 'failed':
                    identity = f"{file}::{test['fullName']}"
                    if identity not in failed:
                        return [], False
                    case['failureDigest'] = failed[identity]
                cases.append(case)
        complete = failure_complete if data['numFailedTests'] else not any(
            suite.get('message') or suite.get('testExecError') or suite.get('errors') or suite.get('status') == 'failed'
            for suite in data['testResults'])
        complete = complete and not data.get('numRuntimeErrorTestSuites') and not data.get('unhandledErrors')
        return cases, bool(complete and len(cases) == data['numPassedTests'] + data['numFailedTests'])
    except (OSError, ValueError, KeyError, TypeError):
        return [], False


def vitest_count(output_path: Path):
    def count(_output: str):
        # A missing report counts zero, which fails the group: vitest must have written it this run.
        try:
            return json.loads(output_path.read_text()).get("numPassedTests", 0)
        except (OSError, ValueError):
            return 0  # missing or truncated: no evidence
    return count


def mac_count(output: str) -> int:
    """Tests the run executed: its last XCTest summary plus its Swift Testing summary; zero when any was skipped."""
    xctest = re.findall(r"Executed (\d+) tests?", output)
    swift_testing = re.findall(r"Test run with (\d+) tests?", output)
    if re.search(r"\d+ tests? skipped", output):
        return 0
    return int(xctest[-1] if xctest else 0) + int(swift_testing[-1] if swift_testing else 0)


def tap_count(output: str) -> int:
    found = re.findall(r"^[#ℹ] pass (\d+)", output, re.M)
    return int(found[-1]) if found else 0


FILE_MARKER = "### verify file: "


def python_count(output: str) -> int:
    """Count executed unittest passes, not skipped/expected-failure cases; plain successful scripts count once."""
    total = 0
    for segment in output.split(FILE_MARKER)[1:]:
        ran = re.findall(r"^Ran (\d+) tests?", segment, re.M)
        if "0" in ran:
            return 0  # an empty declared/owned suite is not hidden by a passing neighbour
        summaries = re.findall(r"^OK \(([^)]*)\)$", segment, re.M)
        excluded = sum(int(n) for summary in summaries for n in re.findall(r"(?:skipped|expected failures)=(\d+)", summary))
        passing = sum(int(n) for n in ran) - excluded if ran else 1
        if passing <= 0:
            return 0
        total += passing
    return total


def per_file(interpreter: str, files: list[str]) -> str:
    return " && ".join(f"echo {shlex.quote(FILE_MARKER + path)} && {interpreter} {shlex.quote(path)}" for path in files)


def test_step_names(group: str, shards: list[list[str]], skipped: bool) -> list[str]:
    """One step per iOS shard, numbered within the group; one step for any other group."""
    if group != "ios" or skipped or len(shards) < 2:
        return [f"tests: {group}"]
    return [f"tests: ios {index}/{len(shards)}" for index in range(1, len(shards) + 1)]


def test_spec(group: str, files: list[str], selectors: list[str], logs: Path, ios_wait: bool = True, gateway_host: str = "local",
              lane: str | None = None, opportunistic: bool = False):
    """One command definition shared by planning and execution. An iOS shard runs on `lane` (else
    the worktree's own lane, or the iPad lane for a `pad` shard); an `opportunistic` one takes a
    host slot only if one is free at once."""
    node = [str(ROOT / "scripts/tron-node"), "exec"]
    if group in ("gateway", "gateway-nested"):
        report = logs / f"{group}-vitest.json"
        config = ["--config", "vitest.nested.config.ts"] if group == "gateway-nested" else []
        # mini.py runs this same gateway.py lane on the mini and returns its report and exit code (README).
        runner = "mini.py" if gateway_host == "mini" else "gateway.py"
        return (["python3", str(ROOT / "tools/verify" / runner), *config, "--reporter=default", "--reporter=json",
                        f"--outputFile.json={report}", *[path[len(GATEWAY) + 1:] for path in files]],
                ROOT / GATEWAY, vitest_count(report))
    if group == "ios":
        pad = getattr(selectors, "pad", False)
        lane = lane or (ios_pad_lane() if pad else None)
        lanes = [*(["--lane", lane] if lane else []), *(["--device-type", IOS_PAD_DEVICE_TYPE] if pad else [])]
        wait = ["--host-slot-wait-seconds", "0"] if opportunistic else ["--host-slot-wait-seconds", "30"] if ios_wait else []
        return ([str(ROOT / "scripts/tron-ios-test"), "run", *lanes, *wait, *[arg for owner in selectors for arg in ("--only-testing", owner)]], ROOT, ios_count)
    if group == "ios-journeys":
        return ([str(ROOT / JOURNEY_HARNESS), "run-ui", *[arg for owner in selectors for arg in ("--only-testing", owner)]], ROOT, None)
    if group == "mac-terminal":
        # Its own Vitest config, on this Mac: the journey needs this host's tailnet sshd (vitest.mac-terminal.config.ts).
        report = logs / f"{group}-vitest.json"
        return (["python3", str(ROOT / "tools/verify/gateway.py"), "--config", "vitest.mac-terminal.config.ts", "--reporter=default",
                 "--reporter=json", f"--outputFile.json={report}", *[path[len(GATEWAY) + 1:] for path in files]], ROOT / GATEWAY, vitest_count(report))
    if group == "mac":
        # The Mac integration target, by test class, as `verify --batch`'s Mac integration lane runs all of it.
        return (["python3", str(ROOT / "tools/verify/mac.py"), *sorted({Path(path).stem for path in files})], ROOT, mac_count)
    if group == "relay":
        # The relay's own Vitest (Workers pool), as `verify --batch`'s relay lane runs it.
        report = logs / f"{group}-vitest.json"
        return (node + ["npm", "test", "--", "--reporter=default", "--reporter=json", f"--outputFile.json={report}",
                        *[path[len(RELAY) + 1:] for path in files]], ROOT / RELAY, vitest_count(report))
    if group == "node-gateway":
        return (node + ["node", "--test", "--test-concurrency=1", *[p[len(GATEWAY) + 1:] for p in files]], ROOT / GATEWAY, tap_count)
    if group == "node":
        return (node + ["node", "--test", "--test-concurrency=1", *files], ROOT, tap_count)
    if group == "python-here":
        return (per_file("python3", files), ROOT, python_count)
    if group == "python":
        command = per_file("python3", files)
        return (["python3", str(ROOT / "tools/verify/mini.py"), "python", command] if gateway_host == "mini" else command, ROOT, python_count)
    return (per_file("bash", files), ROOT, lambda _out: len(files))


IOS_POLL_SECONDS = 0.5


def run_ios_shards(run: Run, shards: list[IosShard], labels: list[str], files: list[str], ios_wait: bool,
                   env: dict, phone_lanes: list[str | None]) -> tuple[list[str], bool]:
    """Run every shard to its outcome, one per lane and at most one per host slot at once, longest
    estimate first; returns the failures and whether admission was deferred.

    A shard started while none of the run's others is in flight acquires its slot as a serial run
    would, and its busy exit 73 defers it and every unstarted shard, never passed. A shard started
    beside one in flight is opportunistic: it takes a slot only if one is free at once. Refused, it
    admitted no work, so it is requeued, and no further lane starts until a running shard ends.
    Every admitted shard runs to its outcome, so one red cannot hide another's."""
    base = run.index
    run.index += len(shards)
    queue = sorted(range(len(shards)), key=lambda index: -shards[index].seconds)
    order = {lane: position for position, lane in enumerate(phone_lanes)}
    refused: set[str | None] = set()  # lanes refused a slot since their last admitted shard, tried last
    rank = lambda name: (name in refused, order.get(name, 0))  # noqa: E731
    free: dict[bool, list[str | None]] = {False: list(phone_lanes), True: [ios_pad_lane()]}
    limit = len(phone_lanes)
    running: dict[int, tuple[Launched, str | None, bool]] = {}
    failures: list[tuple[int, str]] = []
    deferred = False
    try:
        while queue or running:
            while not deferred and len(running) < limit:
                index = next((index for index in queue if free[shards[index].pad]), None)
                if index is None:
                    break
                queue.remove(index)
                lane = free[shards[index].pad].pop(0)
                opportunistic = bool(running)
                command, cwd, _ = test_spec("ios", files, shards[index], run.logs, ios_wait=ios_wait, lane=lane,
                                            opportunistic=opportunistic)
                note = (f" on lane {lane}" if lane else " on this worktree's lane") if len(phone_lanes) > 1 or shards[index].pad else ""
                running[index] = (run.launch(base + index + 1, labels[index], command, cwd, env, note=note), lane, opportunistic)
            if not running:
                break
            finished = [index for index, (launched, _, _) in running.items() if launched.process.poll() is not None]
            if not finished:
                time.sleep(IOS_POLL_SECONDS)
                continue
            for index in finished:
                launched, lane, opportunistic = running.pop(index)
                shard = shards[index]
                free[shard.pad] = sorted(free[shard.pad] + [lane], key=rank)
                code = launched.process.returncode
                if code == 73 and opportunistic:
                    refused.add(lane)
                    free[shard.pad].sort(key=rank)
                    run.withdraw(launched)
                    print(f"{launched.label}: no host slot free beside this run's other lanes; requeued", flush=True)
                    queue.insert(0, index)
                    limit = max(1, len(running))
                    continue
                refused.discard(lane)
                free[shard.pad].sort(key=rank)
                result = run.settle(launched, code, ios_count, (0,))
                if code == 73:
                    # Admission refused: this shard and the rest wait for the batch, never pass.
                    result.update(status="deferred", deferredTests=files)
                    deferred = True
                    continue
                limit = len(phone_lanes)
                if result["status"] == "failed":
                    result["failedTests"] = ios_failures(launched.log.read_text(errors="replace"))
                    print("\n".join(f"    failed: {name}" for name in result["failedTests"]), flush=True)
                    failures.append((index, f"{labels[index]} failed"))
                elif not result.get("tests"):
                    result["status"] = "failed"
                    failures.append((index, f"{labels[index]} ran zero passing tests: an empty group is not evidence"))
                elif all(owner.count("/") == 2 for owner in shard) and result["tests"] != len(shard):
                    # A method selector that matches nothing passes silently; every named test must run.
                    result["status"] = "failed"
                    failures.append((index, f"{labels[index]} passed {result['tests']} of its {len(shard)} named test(s)"))
    except KeyboardInterrupt:
        run.stop(list(run.live))
        raise
    for index in sorted(queue):
        run.skipped(labels[index], "iOS acquisition deferred to batch", index=base + index + 1)
        run.steps[-1].update(status="deferred", deferredTests=files)
    # Report the shards in plan order, whichever lane finished first.
    shard_steps = sorted((step for step in run.steps if step["name"] in labels), key=lambda step: labels.index(step["name"]))
    run.steps[:] = [step for step in run.steps if step["name"] not in labels] + shard_steps
    run.on_update()
    return [message for _, message in sorted(failures)], deferred


def main(argv: list[str]) -> int:
    if "--batch" in argv:
        import batch
        return batch.main([word for word in argv if word != "--batch"])
    parser = argparse.ArgumentParser(prog="scripts/tron verify")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--changed", action="store_true")
    mode.add_argument("--module", metavar="ID")
    mode.add_argument("--all", action="store_true")
    mode.add_argument("--update-locks", metavar="ID")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--skip", default="", help=f"comma-separated runner groups to skip explicitly: {', '.join(SKIPPABLE)}")
    parser.add_argument("--plan", action="store_true", help="print the selection and steps without running them")
    parser.add_argument("--gateway-host", choices=("pool", "local", "mini"), default="pool",
                        help="where the Gateway Vitest and Python test lanes run: the test-host pool (the Mac mini when reachable and idle, "
                             "else this Mac), this Mac, or the mini (tools/verify/mini.py)")
    args = parser.parse_args(argv)
    # Recorded goldens must land in this checkout, so recording runs here.
    gateway_host = "local" if args.update_locks else args.gateway_host
    gateway_reason = "--update-locks records goldens here" if args.update_locks else f"--gateway-host {gateway_host}"
    skip = {item for item in args.skip.split(",") if item}
    if skip - set(SKIPPABLE):
        parser.error(f"--skip accepts only {', '.join(SKIPPABLE)}")
    name = "all" if args.all else "module" if args.module else "update-locks" if args.update_locks else "changed"
    try:
        if not args.plan and git("status", "--porcelain", "--untracked-files=normal").strip():
            raise VerifyError("the worktree has uncommitted or untracked changes; verify reads the committed state, commit first")
        sha = git("rev-parse", "HEAD").strip()
        base = git("merge-base", args.base, "HEAD").strip() if name == "changed" else git("rev-parse", "--verify", args.base).strip()
        result, _ = ownership.check()  # violations fail the ownership step below
        modules = result["modules"]
        paths = changed_paths(base, working=True) if args.plan and name == "changed" else None
        selection = select(name, args.module or args.update_locks, base, modules, result["tracked"], paths=paths)
        change = delta(base) if name == "changed" else None
    except (VerifyError, ownership.GitError) as error:
        print(f"verify: {error}", file=sys.stderr)
        return 2

    nested, mac_terminal = nested_files()
    groups: dict[str, list[str]] = {}
    try:
        for path in selection["tests"]:
            groups.setdefault(runner_of(path, nested, mac_terminal), []).append(path)
        # Selectors are needed only by a run that drives the iOS group (#1522).
        selectors = ios_selectors(groups.get("ios", [])) if "ios" not in skip else []
        shards = ios_shards(selectors, ios_method_seconds() if selectors else {})
        journeys = journey_selectors(groups.get("ios-journeys", [])) if "ios" not in skip else []
    except VerifyError as error:
        print(f"verify: {error}", file=sys.stderr)
        return 2
    skipped_group = lambda group: group.split("-")[0] in skip  # noqa: E731  (--skip ios covers ios-lanes)
    # The iOS lane: a fresh test build of this commit (reused when its stamp matches), the index-store
    # reference check on it, and the selected UIValidation tests on those same products.
    ios_lane = "ios" not in skip and ((name == "all" and any(key.startswith("ios-app/") for key in modules)) or "ios" in groups or (
        name == "changed" and any(key.startswith("ios-app/") for key in selection["modules"])))
    gateway_touched = (name == "all" and any(key.startswith("gateway/") for key in modules)) or any(key.startswith("gateway/") for key in selection["modules"]) \
        or any(path.startswith(f"{GATEWAY}/") for path in selection["tests"])

    print(f"verify --{name}{' ' + (args.module or args.update_locks) if args.module or args.update_locks else ''} at {sha[:12]}"
          f" (base {base[:12]}): {len(selection['tests'])} test file(s) selected", flush=True)
    print(f"  tier: {selection['tier']} — affected checks now" + (
        "; full coverage deferred to explicit verify --batch after landing" if selection["tier"] == "full" and name != "all" else ""), flush=True)
    for reason in selection["reasons"]:
        print(f"  why: {reason}", flush=True)
    if change:
        source, tests = change["sourceLines"], change["testLines"]
        docs = change["docLines"]
        print(f"  delta: source +{source['added']}/-{source['removed']}, tests +{tests['added']}/-{tests['removed']},"
              f" docs +{docs['added']}/-{docs['removed']};"
              f" test files +{len(change['addedTestFiles'])}/-{len(change['deletedTestFiles'])}", flush=True)
        for path, owners in change["besideExistingOwner"].items():
            print(f"  delta: new {path} beside existing owner {', '.join(owners)}: extend it or say why not", flush=True)
        for addition in change["compatAdditions"]:
            print(f"  delta: compatibility wording added in {addition}: no compat code (AGENTS.md); delete it or ask", flush=True)
    for group, files in sorted(groups.items()):
        print(f"  {group}: {len(files)} file(s){' (skipped by --skip)' if skipped_group(group) else ''}", flush=True)
    if any(group.startswith("gateway") or group == "python" for group in groups if not skipped_group(group)) or selection["deferredTests"]:
        if gateway_host == "pool":
            gateway_host, gateway_reason = mini.choose_host()
        print(f"  gateway and python lanes: {'on the Mac mini' if gateway_host == 'mini' else 'on this Mac'} ({gateway_reason})", flush=True)
    else:
        gateway_host, gateway_reason = "local", "no Gateway or Python lane selected"
    if "python-here" in groups and not skipped_group("python-here"):
        print("  python-here lane: on this Mac (its tests read this Mac's Pi session store)", flush=True)
    if "mac-terminal" in groups and not skipped_group("mac-terminal"):
        print("  mac-terminal lane: on this Mac (it needs this host's tailnet sshd)", flush=True)
    plan_steps = ["ownership", "worktree residue", "budgets", "documentation policy", "generated docs", "agent policy", "home layout", "privacy guard", "git diff --check"] \
        + (["gateway typecheck", "gateway lint", "layers gateway"] if gateway_touched else []) \
        + (["ios source policy", "ios build"] if ios_lane else []) + ["layers ios"] \
        + [name for group in sorted(groups) for name in test_step_names(group, shards, skipped_group(group))]
    tron = str(ROOT / "scripts/tron")
    ios_test = str(ROOT / "scripts/tron-ios-test")
    ios_policy = [str(ROOT / "packages/ios-app/scripts/test-source-policy.sh")]
    node = [str(ROOT / "scripts/tron-node"), "exec"]
    # A baseline has no trusted green predecessor: unchanged bytes can already
    # be stale. Keep diff-scoped generation only for actual changed selections.
    baseline_docs = name == "all" or (name == "changed" and not selection["paths"])
    checks = [
        ("ownership", [tron, "ownership"], {}),
        ("worktree residue", [tron, "tidy", "--here", "--landing"], {}),
        ("budgets", [tron, "budgets", "HEAD"], {}),
        ("documentation policy", ["python3", "scripts/check-documentation-policy.py"], {}),
        ("generated docs", [tron, "docs", "check", *([] if baseline_docs else ["--base", base])]
         if baseline_docs or selection["docInputs"] or gateway_touched else None, {}),
        ("agent policy", ["bash", "scripts/check-agent-policy.sh"], {}),
        ("home layout", [tron, "home-layout", "check"], {}),
        ("privacy guard", f"git diff {base}..HEAD | scripts/personal-info-guard.sh --stdin", {}),
        ("git diff --check", ["git", "diff", "--check", f"{base}..HEAD"], {}),
    ]
    gateway_checks = [("gateway typecheck", node + ["npm", "run", "check"]),
                      ("gateway lint", node + ["npm", "run", "lint"]),
                      ("layers gateway", [tron, "layers", "gateway", "--base", base])]
    if args.plan:
        commands = [{"name": label, "command": command, "cwd": ".", **options} for label, command, options in checks]
        if gateway_touched:
            commands += [{"name": label, "command": command, "cwd": "." if label == "layers gateway" else GATEWAY}
                         for label, command in gateway_checks]
        if ios_lane:
            commands.append({"name": "ios source policy", "command": ios_policy})
            commands.append({"name": "ios build", "command": [ios_test, "build", *(["--host-slot-wait-seconds", "30"] if name != "all" else [])], "reuse": "only if current build stamp is fresh"})
        commands.append({"name": "layers ios", "command": [tron, "layers", "ios", "--base", base], "requires": "fresh iOS index"})
        for group, files in sorted(groups.items()):
            if group in NOT_DRIVEN or skipped_group(group):
                commands.append({"name": f"tests: {group}", "notRun": "explicit skip" if skipped_group(group) else "requires owning harness"})
            else:
                for label, shard in zip(test_step_names(group, shards, False),
                                        shards if group == "ios" else [journeys] if group == "ios-journeys" else [selectors]):
                    command, cwd, _ = test_spec(group, files, shard, ROOT / "test-results/verify" / sha, ios_wait=name != "all", gateway_host=gateway_host)
                    commands.append({"name": label, "command": command, "cwd": str(cwd.relative_to(ROOT)),
                                     **({"estimatedSeconds": round(shard.seconds, 1)} if group == "ios" else {})})
        deferred_commands = []
        if selection["deferredTests"]:
            command, cwd, _ = test_spec("gateway-nested", selection["deferredTests"], [], ROOT / "test-results/verify" / sha, gateway_host=gateway_host)
            deferred_commands.append({"name": "tests: gateway-nested", "command": command, "cwd": str(cwd.relative_to(ROOT))})
        print(json.dumps({"selection": selection, "delta": change, "groups": groups, "steps": plan_steps, "commands": commands,
                          "gatewayHost": {"host": gateway_host, "reason": gateway_reason},
                          "deferredCommands": deferred_commands,
                          # Planned iOS commands are each shard's form when it runs alone; beside others in
                          # flight a shard runs on another of these lanes with --host-slot-wait-seconds 0.
                          "iosLanes": [lane or "(this worktree's lane)" for lane in ios_phone_lanes()] + [ios_pad_lane()] if "ios" in groups and "ios" not in skip else [],
                          "batchCommand": [tron, "verify", "--batch"] if selection["tier"] == "full" else None}, indent=2))
        return 0

    # Worktree creation deliberately does not install dependencies. Refuse before
    # any checks (including generated docs) can use an absent/stale install or PATH tsc.
    # A checkout without a Gateway lockfile (a verify fixture) has no install to compare.
    runs_tests = any(group not in NOT_DRIVEN and not skipped_group(group) for group in groups) or bool(selection["deferredTests"])
    if gateway_touched or runs_tests:
        try:
            if gateway_touched:
                require_gateway_compiler()
            if (ROOT / GATEWAY / "package-lock.json").is_file():
                require_install(GATEWAY)
            if "relay" in groups and not skipped_group("relay"):
                require_install(RELAY)
            if "python-here" in groups and not skipped_group("python-here") and (ROOT / CORE / "package-lock.json").is_file():
                require_install(CORE)
        except VerifyError as error:
            print(f"verify: {error}", file=sys.stderr)
            return 2

    run = Run(sha, len(plan_steps))
    started_at = datetime.now(timezone.utc).isoformat()
    attempt_id = str(time.time_ns())
    environment = {'platform': sys.platform, 'architecture': os.uname().machine,
                   'python': list(sys.version_info[:3]), 'gatewayHost': gateway_host}
    config_digest = hashlib.sha256(json.dumps({'selection': selection, 'groups': groups, 'skip': sorted(skip),
        'environment': environment, 'updateLocks': args.update_locks,
        'runnerOverrides': {key: value for key, value in os.environ.items() if key.startswith(('TEST_', 'TRON_', 'VITEST_')) or key in ('CI', 'NODE_OPTIONS')}}, sort_keys=True).encode()).hexdigest()
    report_path = ROOT / "test-results" / "verify" / f"{sha}.json"

    def finish(verdict: str, message: str, announce: bool = True) -> int:
        if verdict == "passed" and any(step["status"] == "deferred" for step in run.steps):
            verdict = "deferred"
            message += "; iOS acquisition deferred to batch, NOT a test pass"
        comparable = {"commit": sha, "selection": selection, "steps": comparable_steps(run.steps), "verdict": verdict}
        case_steps = [step for step in run.steps if step['name'].startswith('tests:')]
        report = {"schema": "tron.verify.v1", "commit": sha, "verdict": verdict, "message": message,
                  "attemptId": attempt_id, "configDigest": config_digest, "environment": environment, "startedAt": started_at,
                  "endedAt": datetime.now(timezone.utc).isoformat() if verdict != 'running' else None,
                  "caseEvidenceComplete": bool(case_steps) and all(step.get('caseEvidenceComplete') for step in case_steps),
                  "resultDigest": hashlib.sha256(json.dumps(comparable, sort_keys=True).encode()).hexdigest(),
                  "selection": selection, "delta": change, "groups": groups, "skipped": sorted(skip), "steps": run.steps,
                  "gatewayHostReason": gateway_reason,
                  # A selection, even --all, is not the complete post-land batch.
                  "checkpointEligible": False,
                  "passingTests": sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))}
        temporary = report_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, report_path)
        if announce:
            print(f"verify: {verdict.upper()} — {message}", flush=True)
            print(f"verify: report {report_path.relative_to(ROOT)} (result digest {report['resultDigest'][:16]})", flush=True)
        return 0 if verdict in ("passed", "deferred") else 1

    run.on_update = lambda: finish("interrupted" if any(s["status"] == "interrupted" for s in run.steps) else "running",
                                   "partial results; verification is not complete", announce=False)
    run.on_update()
    try:
        for label, command, options in checks:
            if command is None:
                run.skipped(label, "the change touches no Markdown, manifest or Gateway source a generated block reads")
            elif run.step(label, command, **options)["status"] == "failed":
                return finish("failed", f"{label} failed")
        if gateway_touched:
            for label, command in gateway_checks:
                cwd = ROOT if label == "layers gateway" else ROOT / GATEWAY
                if run.step(label, command, cwd=cwd)["status"] == "failed":
                    return finish("failed", f"{label} failed")
        # The iOS reference check reads the index of this commit's own test build (#1459). The iOS
        # lane builds it when the stamp is stale; a selection without iOS reports it skipped, never passed.
        stale = ios_index_stale()
        ios_deferred = False
        if ios_lane:
            if run.step("ios source policy", ios_policy)["status"] == "failed":
                return finish("failed", "ios source policy failed")
            if stale is None:
                run.reused("ios build", "the test products are already stamped for this commit", [ios_test, "build", *(["--host-slot-wait-seconds", "30"] if name != "all" else [])])
            else:
                built = run.step("ios build", [ios_test, "build", *(["--host-slot-wait-seconds", "30"] if name != "all" else [])])
                if built["exit"] == 73:
                    built.update(status="deferred", deferredTests=groups.get("ios", []))
                    ios_deferred = True
                elif built["status"] == "failed":
                    return finish("failed", "ios build failed")
            if not ios_deferred:
                stale = None
        if ios_deferred:
            run.skipped("layers ios", "iOS slot unavailable; build/index/tests deferred to batch")
        elif stale is not None:
            run.skipped("layers ios", f"no fresh iOS index for this commit: {stale}")
        elif run.step("layers ios", [tron, "layers", "ios", "--base", base])["status"] == "failed":
            return finish("failed", "layers ios failed")

        update = {"TRON_UPDATE_LOCKS": args.update_locks} if args.update_locks else {}
        not_run = []
        for group in sorted(groups):
            files = groups[group]
            label = f"tests: {group}"
            if skipped_group(group):
                run.skipped(label, f"{len(files)} file(s) skipped by --skip {group.split('-')[0]}")
                continue
            if group in NOT_DRIVEN:
                not_run.append(group)
                run.skipped(label, f"{len(files)} file(s) need their own {group} lane(s), which verify does not drive; pass --skip {group.split('-')[0]} to accept")
                continue
            if group == "ios":
                labels = test_step_names("ios", shards, False)
                if ios_deferred:
                    for label in labels:
                        run.skipped(label, "iOS acquisition deferred to batch")
                        run.steps[-1].update(status="deferred", deferredTests=files)
                    continue
                env = {"TEST_RUNNER_TRON_UPDATE_LOCKS": args.update_locks} if args.update_locks else {}
                failed_shards, ios_deferred = run_ios_shards(run, shards, labels, files, name != "all", env, ios_phone_lanes())
                # Every admitted shard runs, so one red cannot hide another selected test's outcome.
                if failed_shards:
                    return finish("failed", "; ".join(failed_shards))
                continue
            if group == "ios-journeys":
                command, cwd, _ = test_spec(group, files, journeys, run.logs)
                result = run.step(label, command, cwd=cwd, env={"TRON_IOS_E2E_UI_LANES": str(min(JOURNEY_LANES, len(journeys)))})
                reports, failed, missing = journey_evidence((ROOT / result["log"]).read_text(errors="replace"), journeys, sha)
                result.update(journeyReports=reports, tests=len(journeys) - len(missing))
                if failed or result["status"] == "failed":
                    result.update(status="failed", failedTests=failed)
                    print("\n".join(f"    failed: {journey}" for journey in failed), flush=True)
                    return finish("failed", f"{label} failed")
                if missing:
                    result["status"] = "failed"
                    return finish("failed", f"{label}: no passing report for this commit from {', '.join(missing)}")
                continue
            command, cwd, count = test_spec(group, files, selectors, run.logs, ios_wait=name != "all", gateway_host=gateway_host)
            report = run.logs / f"{group}-vitest.json"
            report.unlink(missing_ok=True)
            on_mini = gateway_host == "mini" and (group.startswith("gateway") or group == "python")
            env = {**update, "TRON_VERIFY_COMMIT": sha} if on_mini else update
            result = run.step(label, command, cwd=cwd, count=count, env=env)
            if on_mini and (reason := mini.no_result_reason(result["exit"], (ROOT / result["log"]).read_text(errors="replace"))):
                # Not a test outcome, so the run is incomplete, not failed.
                result.update(status="no result", reason=reason)
                return finish("incomplete", f"{label}: the mini gave no result: {reason}")
            if group in ('gateway', 'gateway-nested'):
                result['caseOutcomes'], result['caseEvidenceComplete'] = case_outcomes(report)
            if group in ("gateway", "gateway-nested") and result["status"] == "failed":
                failed, _ = gateway_failures(report, (ROOT / result["log"]).read_text(errors="replace"))
                result["failedTests"] = list(failed)
                print("\n".join(f"    failed: {identity}" for identity in failed), flush=True)
            if result["status"] == "failed":
                return finish("failed", f"{label} failed")
            if not result.get("tests"):
                result["status"] = "failed"
                return finish("failed", f"{label} ran zero passing tests: an empty group is not evidence")
        passing = sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))
        if not_run:
            return finish("incomplete", f"selected tests were not run: {', '.join(not_run)} (pass --skip to accept explicitly)")
        if passing == 0 and any(step["status"] == "deferred" for step in run.steps):
            return finish("passed", "affected checks passed; iOS tests deferred to full batch")
        if passing == 0 and selection["docsOnly"]:
            return finish("passed", "Empty or documentation-only change: static/documentation checks are its evidence")
        if passing == 0 and selection["deferredTests"]:
            return finish("passed", f"affected static checks passed; {len(selection['deferredTests'])} serial test file(s) deferred; full batch is not green")
        if passing == 0:
            return finish("failed", "zero tests ran: an empty selection is not evidence")
        groups_run = len({step["name"].split()[1] for step in run.steps if step["name"].startswith("tests:") and step["status"] == "ok"})
        return finish("passed", f"{passing} passing test(s) across {groups_run} runner group(s)"
                      + (f"; {len(selection['deferredTests'])} serial file(s) deferred to explicit batch" if selection["deferredTests"] else "")
                      + (f"; skipped by request: {', '.join(sorted(skip))}" if skip else ""))

    except KeyboardInterrupt:
        finish("interrupted", "owned step stopped; partial results retained, not a pass")
        return 130

if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("verify: INTERRUPTED — completed steps and live logs retained; not a pass", file=sys.stderr)
        sys.exit(130)
