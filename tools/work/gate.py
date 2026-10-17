#!/usr/bin/env python3
"""`scripts/tron gate`: the one runner for every verification step (README.md#gate, #1022).

`gate-catalog.json` is the source of truth: each step's trigger, command, cache
inputs, budget, hard timeout, resource class and the gate it unlocks. The
classifier turns the change (the worktree against its merge base with the
configured base branch) into the ordered plan of the steps it needs; plan order
is catalog order, so the same change always gets the same plan.

A step expands into shards. Each shard has its own content-addressed cache key
(its command, declared source/dependency inputs, execution contract and verifier),
so a retry reruns only failed or invalidated shards, including in a dirty worktree. A
passing shard is recorded under the common Git directory; `cacheScope:
worktree` keys also bind the worktree because their products live there, and
`cacheScope: source` keys also bind its exact commit and tree because their
products are stamped with that source state.

Running prints one line per shard as it starts and a heartbeat with elapsed
time, budget and live tree RSS while it runs, stops at the first failure with
the log tail, and stops a shard that exceeds its hard timeout with its whole
process tree, naming it. Heavy
shards wait for the host-wide heavy queue (heavy.py) with their expected RSS;
light shards never wait. Every finished shard appends its wall time, peak tree
RSS and CPU to `<git common dir>/work/gate/metrics.jsonl`, which `report`
summarizes.
"""
from __future__ import annotations

import argparse
import ast
import contextlib
import fnmatch
import hashlib
import json
import os
import re
import shlex
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import flakes  # noqa: E402
import heavy  # noqa: E402
import ledger  # noqa: E402

# TRON_GATE_CATALOG exists for scripts/test-gate.py, which exercises the runner on a fixture catalog.
CATALOG = Path(os.environ.get("TRON_GATE_CATALOG") or Path(__file__).resolve().parent / "gate-catalog.json")
HEARTBEAT_SECONDS = float(os.environ.get("TRON_GATE_HEARTBEAT_SECONDS") or 15)
SAMPLE_SECONDS = 0.5
# How long a stopped step's processes get to finish their own cleanup after SIGTERM before
# SIGKILL: the iOS lease holder waits up to 30 s for its command tree, then releases its
# simulator. scripts/test-gate.py shortens it for its fixtures.
STOP_GRACE_SECONDS = float(os.environ.get("TRON_GATE_STOP_GRACE_SECONDS") or 45)
EXCERPT_LINES = 40
_TEST_FILE = re.compile(r"\.(test|spec)\.(ts|tsx|mts|mjs|js)$")
_TS_FILE = re.compile(r"\.(ts|tsx|mts|mjs|js|json)$")
_SCRIPT_SUFFIXES = {".py": "python", ".mjs": "node", ".js": "node", ".sh": "shell"}
# The verification ladder (README.md#tiers): L0 static, type and build checks; L1 self-contained
# tool and unit-level suites; L2 contract checks on shared fixtures; L3 real-boundary Gateway,
# script and Mac E2E with a faux model; L4 simulator journeys; L5 real-model evals, which never
# gate a merge. `gate report` publishes wall time per tier.
TIERS = ("L0", "L1", "L2", "L3", "L4")


class GateError(RuntimeError):
    pass


# ---------------------------------------------------------------- git and paths

def _git(root: Path, *args: str, env: Optional[dict] = None) -> str:
    done = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, env=env)
    if done.returncode != 0:
        raise GateError(f"git {' '.join(args[:2])} failed: {done.stderr.strip()}")
    return done.stdout


def _common_dir(root: Path) -> Path:
    return Path(_git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())


def _git_dir(root: Path) -> Path:
    return Path(_git(root, "rev-parse", "--path-format=absolute", "--git-dir").strip())


def workspace_tree(root: Path) -> str:
    """The tree of the worktree as it is now, tracked edits and untracked files included.

    Built in a private copy of the index, so the real index is untouched.
    """
    with tempfile.TemporaryDirectory(prefix="tron-gate-index-") as temporary:
        index = Path(temporary) / "index"
        real = _git_dir(root) / "index"
        if real.exists():
            index.write_bytes(real.read_bytes())
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        _git(root, "add", "-A", ".", env=env)
        return _git(root, "write-tree", env=env).strip()


def _glob(pattern: str) -> re.Pattern:
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(f"^{out}$")


def _matches(path: str, patterns: List[str]) -> bool:
    return any(_glob(p).match(path) for p in patterns)


# ---------------------------------------------------------------- catalog and plan

def load_catalog(path: Path = CATALOG) -> dict:
    catalog = json.loads(path.read_text())
    ids = [step["id"] for step in catalog["steps"]]
    if len(ids) != len(set(ids)):
        raise GateError("gate catalog has duplicate step ids")
    for step in catalog["steps"]:
        for name in ("inputs", "budgetSeconds", "timeoutSeconds", "class", "expectedRssMb", "pass", "unlocks"):
            if name not in step:
                raise GateError(f"gate catalog step {step['id']} lacks {name}")
        if "command" not in step and "shardCommands" not in step:
            raise GateError(f"gate catalog step {step['id']} lacks command")
        if step["class"] not in ("light", "heavy"):
            raise GateError(f"gate catalog step {step['id']} has class {step['class']}")
        if step["budgetSeconds"] > step["timeoutSeconds"]:
            raise GateError(f"gate catalog step {step['id']} has a budget beyond its hard timeout")
        if step.get("tier") not in TIERS:
            raise GateError(f"gate catalog step {step['id']} lacks a verification tier ({', '.join(TIERS)})")
    steps = {step["id"]: step for step in catalog["steps"]}
    for step in catalog["steps"]:
        for name in step.get("after", []):
            if name not in steps:
                raise GateError(f"gate catalog step {step['id']} has unknown prerequisite {name}")
    for name in catalog.get("ciSteps", []):
        if name not in steps or steps[name].get("hosted") != "safe":
            raise GateError(f"CI step {name} is not hosted-safe")
    return catalog


@dataclass
class Shard:
    step: dict
    index: int
    count: int
    command: str
    label: str = ""

    @property
    def name(self) -> str:
        return self.step["id"] + (f"[{self.label}]" if self.label else (f"#{self.index}/{self.count}" if self.count > 1 else ""))

    @property
    def tier(self) -> str:
        # A step whose shards cross different boundaries (`journey`: any --tests command)
        # names the higher tier for commands that match a rule.
        for rule in self.step.get("tierRules", []):
            if re.search(rule["match"], self.command):
                return rule["tier"]
        return self.step["tier"]


@dataclass
class Change:
    root: Path
    base_ref: str
    merge_base: str
    tree: str
    paths: List[str]
    tests: List[str] = field(default_factory=list)

    def existing(self) -> List[str]:
        return [p for p in self.paths if (self.root / p).is_file()]


def change_for(root: Path, base_ref: str, tests: List[str]) -> Change:
    if subprocess.run(["git", "rev-parse", "--verify", "-q", f"{base_ref}^{{commit}}"], cwd=root,
                      capture_output=True).returncode != 0:
        raise GateError(f"{base_ref} is not fetched; fetch it first")
    merge_base = _git(root, "merge-base", base_ref, "HEAD").strip()
    tree = workspace_tree(root)
    output = _git(root, "diff", "--name-only", "--no-renames", "-z", merge_base, tree)
    return Change(root, base_ref, merge_base, tree, [p for p in output.split("\0") if p], list(tests))


def _script_kind(root: Path, relative: str) -> Optional[str]:
    path = Path(relative)
    kind = _SCRIPT_SUFFIXES.get(path.suffix)
    if kind is None and not path.suffix and path.parts[:1] == ("scripts",):
        first = (root / path).read_text(errors="replace").splitlines()[:1]
        shebang = first[0] if first else ""
        if re.search(r"^#!.*\b(ba|z)?sh\b", shebang):
            kind = "shell"
        elif re.search(r"^#!.*\bpython3?\b", shebang):
            kind = "python"
    return kind


IOS_METHODS_PER_SHARD = 2
SUITE_SPLIT_CLASSES = 6


def _suite_shards(root: Path, suite: str) -> List[str]:
    """Large unittest suites run one class per shard, including inherited cases.

    Source-line grouping packed unrelated runtime costs past the hard timeout.
    Class boundaries are deterministic and let retries reuse each completed class.
    """
    source = (root / suite).read_text(errors="replace")
    # unittest discovers indirect subclasses too (e.g. ReleaseFixture inherits
    # OwnedLaneFixture). Sharding must preserve that complete discovered suite.
    classes = [node for node in ast.parse(source).body if isinstance(node, ast.ClassDef)]
    test_classes: set = set()
    for node in classes:
        bases = [ast.unparse(base) for base in node.bases]
        if "unittest.TestCase" in bases or any(base in test_classes for base in bases):
            test_classes.add(node.name)
    if len(test_classes) < SUITE_SPLIT_CLASSES:
        return [f"python3 -B {suite}"]
    return [f"python3 -B {suite} {node.name}" for node in classes if node.name in test_classes]


# Swift comments and string literals, blanked before scanning so braces and `func test` inside
# them are not read as declarations.
_SWIFT_NOISE = re.compile(r'//[^\n]*|/\*.*?\*/|#*""".*?"""#*|#*"(?:\\.|[^"\\\n])*"#*', re.S)
_SWIFT_ATTRS = r"(?:@\w+(?:\([^()]*\))?\s*)"
_SWIFT_MODIFIERS = r"(?:public|internal|open|final|override|nonisolated|private|fileprivate|static|class|mutating)"
# The head of a top-level type body: `@MainActor final class X: XCTestCase {`, `extension X {`.
_SWIFT_TYPE_HEAD = re.compile(rf"(?:^|\s)(?:{_SWIFT_ATTRS}|{_SWIFT_MODIFIERS}\s+)*(class|struct|enum|actor|extension|protocol)\s+"
                              r"([A-Za-z_]\w*)\s*(?::\s*([^{]*?))?\s*(?:where\b[^{]*)?$")
# The head of a method body XCTest runs: an instance `func testX()` with no parameters, after
# any attributes and modifiers (`@MainActor`, `@available(...)`, `override`, on the same line or not).
_SWIFT_TEST_HEAD = re.compile(rf"(?:^|\s)((?:{_SWIFT_ATTRS}|{_SWIFT_MODIFIERS}\s+)*)func\s+(test\w*)\s*\(\s*\)\s*"
                              r"(?:async\s*)?(?:throws\s*)?(?:->\s*(?:Void|\(\s*\))\s*)?$")


def _swift_declarations(source: str) -> tuple:
    """Top-level types of one Swift file and the XCTest methods each declares.

    Returns ({type: [inherited names]} for classes, [(type, method)] in source order). A method
    counts only as a direct member of a top-level class or extension body; methods of nested
    types, local functions and static/private functions are not XCTest test methods.
    """
    text = _SWIFT_NOISE.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), source)
    classes: Dict[str, List[str]] = {}
    methods: list = []
    stack: List[Optional[str]] = []  # the enclosing top-level type name, or None for any other body
    head_start = 0
    for match in re.finditer(r"[{};]", text):
        head, head_start = text[head_start:match.start()], match.end()
        if match.group() == ";":
            continue
        if match.group() == "}":
            if stack:
                stack.pop()
            continue
        owner = None
        if not stack:
            declared = _SWIFT_TYPE_HEAD.search(head)
            if declared:
                owner = declared.group(2)
                if declared.group(1) == "class":
                    classes[owner] = [base.strip() for base in (declared.group(3) or "").split(",") if base.strip()]
        elif len(stack) == 1 and stack[0]:
            test = _SWIFT_TEST_HEAD.search(head)
            if test and not re.search(r"\b(static|class|private|fileprivate)\s", test.group(1)):
                methods.append((stack[0], test.group(2)))
        stack.append(owner)
    return classes, methods


# Each UI test target's source folder (packages/ios-app/project.yml). A target is its own
# bundle: its classes see only their own folder.
IOS_TEST_TARGETS = {"packages/ios-app/UITests/": "TronMobileUITests",
                    "packages/ios-app/SwiftAppUITests/": "TronSwiftAppUITests"}


def _ios_journey_shards(root: Path, paths: List[str]) -> List[str]:
    """One shard per IOS_METHODS_PER_SHARD test methods of each changed UI test class, all
    from the same stamped build products; methods are read from the files every time.

    Test classes are a UI test target's classes that inherit XCTestCase, directly or through
    another test class; a changed file contributes the test methods it declares in them,
    including through an extension in a file of another name.
    """
    shards = []
    for folder, target in IOS_TEST_TARGETS.items():
        excluded = folder + "RealGateway/"
        files = {}
        for path in sorted((root / folder).rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            # A class that names its own harness (`// gate-journey:`) runs as a journey instead.
            if not relative.startswith(excluded) and not _harness_journey(path):
                files[relative] = _swift_declarations(path.read_text(errors="replace"))
        bases = {name: inherited for classes, _ in files.values() for name, inherited in classes.items()}
        tests = {"XCTestCase"}
        while True:
            found = {name for name, inherited in bases.items() if inherited and inherited[0] in tests} - tests
            if not found:
                break
            tests |= found
        tests.discard("XCTestCase")
        by_class: Dict[str, List[str]] = {}
        for path in paths:
            for owner, method in files.get(path, ({}, []))[1]:
                if owner in tests:
                    by_class.setdefault(owner, []).append(method)
        for owner, methods in by_class.items():
            methods = list(dict.fromkeys(methods))
            for start in range(0, len(methods), IOS_METHODS_PER_SHARD):
                shards.append(" ".join(f"--only-testing {target}/{owner}/{m}"
                                       for m in methods[start:start + IOS_METHODS_PER_SHARD]))
    return shards


def _select(name: str, change: Change, code: List[str]) -> List[str]:
    """Arguments a selecting step needs from the change; empty means the step is not needed."""
    root = change.root
    if name == "script-syntax":
        kinds: Dict[str, List[str]] = {"python": [], "node": [], "shell": []}
        for path in change.existing():
            kind = _script_kind(root, path)
            if kind:
                kinds[kind].append(shlex.quote(path))
        commands = []
        if kinds["python"]:
            commands.append("python3 -B -c 'import ast,sys\nfor p in sys.argv[1:]: ast.parse(open(p, \"rb\").read(), p)' "
                            + " ".join(kinds["python"]))
        commands += [f"node --check {p}" for p in kinds["node"]]
        commands += [f"bash -n {p}" for p in kinds["shell"]]
        return [" && ".join(commands)] if commands else []
    if name == "gateway-affected":
        prefix = "packages/gateway/"
        files = [p[len(prefix):] for p in code if p.startswith(prefix) and (root / p).is_file() and _TS_FILE.search(p)
                 and not p.startswith(prefix + "scripts/") and Path(p).name not in ("package.json", "package-lock.json")]
        return [" ".join(shlex.quote(f) for f in files)] if files else []
    if name == "tooling-tests":
        suites = []
        for path in change.existing():
            if path == "scripts/test-tron-mac-replace.py":
                continue  # mac.replace-e2e owns this heavy suite, including edits to the suite itself.
            if re.match(r"^scripts/test-[\w-]+\.py$", path):
                suites.append(path)
            elif path.startswith("tools/work/"):
                stem = Path(path).stem
                target = {"gate": "test-gate", "heavy": "test-tron-heavy", "verify": "test-gate", "land": "test-work-land",
                          "ledger": "test-gate", "report": "test-gate", "flakes": "test-gate", "work_status": "test-work-start",
                          "claim": "test-work-start", "comments": "test-work-start", "gh": "test-work-auth",
                          "cli": "test-gate"}.get(stem, f"test-work-{stem}")
                targets = [target]
                if stem in ("gate", "cli", "ledger", "land", "mainline"):
                    targets.extend(("test-work-land", "test-work-mainline"))
                if stem == "gate":
                    targets.append("test-gate-modules")
                suites.extend(f"scripts/{target}.py" for target in targets if (root / f"scripts/{target}.py").is_file())
            elif re.match(r"^scripts/tron_mac_(replace|reinstall)", path):
                pass  # mac.replace-e2e owns these
            elif path.startswith("scripts/") and Path(path).suffix in (".py", ""):
                stem = Path(path).name.replace("_", "-").removesuffix(".py")
                for candidate in (f"scripts/test-{stem}.py",):
                    if (root / candidate).is_file():
                        suites.append(candidate)
        return [command for suite in dict.fromkeys(suites) for command in _suite_shards(root, suite)]
    if name == "ios-journeys":
        return list(dict.fromkeys(_ios_journey_shards(root, change.existing()))) or [""]
    if name == "named-journeys":
        # The --tests commands, plus the harness of each changed UI test class that needs one
        # (it cannot pass under the plain runner, so it is never silently left out).
        harnesses = [_harness_journey(root / path) for path in change.existing()
                     if path.startswith(tuple(IOS_TEST_TARGETS)) and path.endswith("UITests.swift")]
        return list(dict.fromkeys([*change.tests, *(command for command in harnesses if command)]))
    raise GateError(f"unknown selector {name}")


def _harness_journey(path: Path) -> Optional[str]:
    """The `// gate-journey: <command>` a UI test class declares when it needs a harness
    (a real sshd, a real Gateway) that `scripts/tron-ios-test run` alone does not start."""
    match = re.search(r"^// gate-journey: (scripts/\S+)$", path.read_text(errors="replace"), re.M)
    return match.group(1) if match else None


def _pi_graph_changed(change: Change) -> bool:
    manifests = {"packages/gateway/package.json", "packages/gateway/package-lock.json"}
    if not manifests.intersection(change.paths):
        return False
    comparator = Path(__file__).resolve().parents[2] / "packages/gateway/scripts/compare-pi-sdk-graph.mjs"
    result = subprocess.run(["node", str(comparator), change.merge_base, change.tree, str(change.root)],
                            capture_output=True, text=True)
    if result.returncode:
        raise GateError("Pi graph classification failed: " + result.stderr.strip())
    try:
        changed = json.loads(result.stdout)["changed"]
        if not isinstance(changed, bool):
            raise ValueError("changed is not a boolean")
        return changed
    except (ValueError, KeyError) as error:
        raise GateError(f"Pi graph classification returned invalid evidence: {error}") from error


def plan(catalog: dict, change: Change) -> List[Shard]:
    """The ordered shards the change needs (catalog order; shards in index order)."""
    exclude = catalog.get("codeExclude", [])
    code = [p for p in change.paths if not _matches(p, exclude)]
    selected: List[Shard] = []
    pi_changed: Optional[bool] = None
    for step in catalog["steps"]:
        trigger = step["trigger"]
        candidates = code if trigger.get("code") else change.paths
        needed = trigger.get("always") or ("paths" in trigger and any(_matches(p, trigger["paths"]) for p in candidates))
        if trigger.get("piGraph"):
            if pi_changed is None:
                pi_changed = _pi_graph_changed(change)
            needed = needed or pi_changed
        if "paths" not in trigger and "select" in trigger:
            needed = True
        if not needed:
            continue
        selections = [""]
        if "select" in trigger:
            selections = _select(trigger["select"], change, code)
            if not selections:
                continue
        expanded = expand(step, change, selections)
        selected.extend(expanded)
    # A whole-suite step covers its affected-only subset, which would only repeat its tests.
    chosen = {shard.step["id"] for shard in selected}
    return [shard for shard in selected if shard.step.get("supersededBy") not in chosen]


def expand(step: dict, change: Change, selections: List[str]) -> List[Shard]:
    """A step's shards: its named shard commands, N numbered shards, or one per selection."""
    trigger = step["trigger"]
    if step.get("shardCommands"):
        named = step["shardCommands"]
        return [Shard(step, index, len(named), _render(command, change, "", index, len(named)), label)
                for index, (label, command) in enumerate(named.items(), 1)]
    shards = int(step.get("shards", 1))
    if shards > 1:
        return [Shard(step, index, shards, _render(step["command"], change, selections[0], index, shards))
                for index in range(1, shards + 1)]
    expanded = []
    for index, selection in enumerate(selections, 1):
        label = ""
        if len(selections) > 1 or trigger.get("select") in ("named-journeys", "ios-journeys", "tooling-tests"):
            label = _label(trigger.get("select"), selection, index)
        expanded.append(Shard(step, index, len(selections), _render(step["command"], change, selection, index, len(selections)), label))
    return expanded


def _label(select: Optional[str], selection: str, index: int) -> str:
    if select == "ios-journeys":
        if not selection:
            return "smoke"
        tests = [part.split("/")[-2:] for part in selection.split() if "/" in part]
        return f"{tests[0][0]}.{tests[0][1]}" + (f"+{len(tests) - 1}" if len(tests) > 1 else "")
    if select == "tooling-tests":
        parts = selection.split()
        stem = Path(parts[2]).stem
        return stem if len(parts) == 3 else f"{stem}:{parts[3]}.."
    return str(index)


def _render(command: str, change: Change, selection: str, index: int, count: int) -> str:
    return (command.replace("{merge_base}", change.merge_base).replace("{select}", selection)
            .replace("{shard}", str(index)).replace("{shards}", str(count)))


# ---------------------------------------------------------------- cache

_extra_cache: Dict[str, str] = {}


def _key_extra(name: str) -> str:
    if name not in _extra_cache:
        if name == "xcode":
            done = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
            _extra_cache[name] = done.stdout.strip()
        else:
            raise GateError(f"unknown keyExtra {name}")
    return _extra_cache[name]


def _launch(command: str) -> str:
    """What a command runs from: its `cd <dir>`, or a repository script it starts with."""
    match = re.match(r"\s*cd (\S+) &&", command)
    if match:
        return f"cd {match.group(1)}"
    first = (command.split() or [""])[0]
    return first if "/" in first and not first.startswith("/") else ""


def _command_owners(catalog: dict, shard: Shard) -> List[dict]:
    launch = _launch(shard.command)
    return [other for other in catalog["steps"] if other["id"] != shard.step["id"] and launch and any(
        _launch(command) == launch for command in (other.get("shardCommands") or {"": other.get("command", "")}).values())]


def step_inputs(catalog: dict, shard: Shard) -> List[str]:
    """The paths a shard's result depends on (README.md#shards-and-cache).

    A step with `inputsFromCommand` (`journey`, any --tests command) takes the inputs of
    the catalog steps that launch the same way (`cd packages/gateway && ...`, or the same
    script), so a landing elsewhere in the repository does not invalidate it; a command
    no step launches like keeps the whole repository.
    """
    step = shard.step
    if not step.get("inputsFromCommand"):
        return step["inputs"]
    launch = _launch(shard.command)
    owners = _command_owners(catalog, shard)
    if not owners:
        return ["."]
    paths = [path for owner in owners for path in owner["inputs"]]
    if not launch.startswith("cd "):
        paths.append(launch)
    return sorted(set(paths))


def input_listing(root: Path, tree: str, step: dict, inputs: List[str], code_exclude: List[str]) -> str:
    """The git listing a shard's key hashes. A code step (`trigger.code`) leaves out the
    paths its trigger ignores (`codeExclude`), so a Markdown-only change neither starts it
    nor invalidates its pass."""
    listing = _git(root, "ls-tree", "-r", "--full-tree", tree, "--", *inputs)
    if not step["trigger"].get("code"):
        return listing
    return "".join(line + "\n" for line in listing.splitlines() if not _matches(line.split("\t", 1)[1], code_exclude))


def _verification_context(root: Path, change: Change, config: dict) -> dict:
    # Verifier code must not inherit application-specific exclusions. Its catalog
    # is keyed separately below; Markdown is documentation, not loaded Python.
    return {"catalog": load_catalog(), "prelude": config["verify"]["prelude"],
            "verifier": input_listing(root, change.tree, {"trigger": {"code": True}},
                                      ["tools/work", "scripts/tron-node", ".node-version"],
                                      ["**/*.md", "tools/work/gate-catalog.json"])}


def _step_contract(catalog: dict, shard: Shard) -> Optional[dict]:
    """Bind declared prerequisites/command owners without invalidating independent steps."""
    pending = [shard.step]
    if shard.step.get("inputsFromCommand"):
        owners = _command_owners(catalog, shard)
        if not owners:
            return None  # No dependency proof: retain whole-repository verification.
        pending.extend(owners)
    by_id = {step["id"]: step for step in catalog["steps"]}
    seen = {}
    prerequisites = set()
    while pending:
        step = pending.pop()
        if step["id"] in seen:
            continue
        seen[step["id"]] = step
        if step["id"] != shard.step["id"] and step.get("inputsFromCommand"):
            return None  # An unexpanded prerequisite cannot establish its command owners.
        for name in step.get("after", []):
            prerequisites.add(name)
            pending.append(by_id[name])
    return {"globals": {key: value for key, value in catalog.items() if key != "steps"},
            "steps": [seen[name] for name in sorted(seen)], "after": sorted(prerequisites)}


def cache_key(root: Path, change: Change, shard: Shard, context: dict, without: tuple = ()) -> Optional[str]:
    """The shard's key; with `without`, the key of a pass that did not execute those
    module scopes (README.md#module-scoped-journeys), or None when a scope's surface is
    unproven. The plain key never returns None."""
    step = shard.step
    catalog = context["catalog"]
    exclusions = catalog.get("codeExclude", [])
    surfaces = {_scope_name(scope): module_surface(root, change.tree, scope) for scope in without}
    if None in surfaces.values():
        return None
    listing = _without_scopes(input_listing(root, change.tree, step, step_inputs(catalog, shard), exclusions), without)
    contract = _step_contract(catalog, shard)
    # Bind prerequisite *inputs*, not their source stamp: a new commit rebuilds a
    # stamped product, but unchanged source inputs may still justify a prior test pass.
    dependencies = [{"id": dependency["id"],
                     # Inferred owners' paths already flow through step_inputs and
                     # this shard's code exclusions; explicit prerequisites own theirs.
                     "inputs": _without_scopes(input_listing(root, change.tree, dependency, dependency["inputs"],
                                                             exclusions), without)
                               if dependency["id"] in contract["after"] else None,
                     "extra": [_key_extra(name) for name in dependency.get("keyExtra", [])]}
                    for dependency in (contract or {}).get("steps", []) if dependency["id"] != step["id"]]
    scope = {
        "gate": 1,
        # Inputs alone do not prove equivalent verification: a new prelude, hard
        # bound, catalog rule or verifier implementation requires fresh evidence.
        **context,
        "catalog": contract or catalog,
        "dependencies": dependencies,
        "unknownInputs": _without_scopes(input_listing(root, change.tree, step, ["."], exclusions), without)
                         if contract is None else None,
        "step": step["id"],
        "command": shard.command,
        "inputs": hashlib.sha256(listing.encode()).hexdigest(),
        "extra": [_key_extra(name) for name in step.get("keyExtra", [])],
        "worktree": str(root) if step.get("cacheScope") in ("worktree", "source") else None,
    }
    # Products stamped with the exact source state (the iOS test products, whose runner
    # refuses a build from another commit) are valid only for that commit and tree.
    if step.get("cacheScope") == "source":
        scope["source"] = [_git(root, "rev-parse", "HEAD").strip(), change.tree]
    # Commands that compare against the merge base depend on it beyond their inputs.
    if "{merge_base}" in step.get("command", ""):
        scope["mergeBase"] = change.merge_base
    if without:
        scope["moduleSurfaces"] = surfaces
    return hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()


# ---------------------------------------------------------------- module-scoped journeys

# What a module can change in a client process without running any of its own (counted)
# code, beyond its printed package interface: static and global stored values, enum raw
# values, synthesized decoding, and Objective-C or symbol-level entry points. A module
# whose surface or sources use one keeps the whole-input key (README.md#module-scoped-journeys).
# A stored property prints without an accessor block; a global one starts at column 0.
_SURFACE_UNPROVEN = re.compile(r"^(?:\S+ )*(?:let|var) [^{]*$|^\s+(?:\S+ )*static (?:\S+ )*(?:let|var) [^{]*$"
                               r"|\brawValue\b|\b(?:Decodable|Codable)\b|@objc(?! deinit\b)", re.M)
_SOURCE_UNPROVEN = re.compile(r"@(?:objc|_cdecl|_silgen_name|_section|_used)\b")
# A module compiles alone in seconds; a hung compiler must not hang planning (no proof then).
SURFACE_TIMEOUT_SECONDS = 120


def _without_scopes(listing: str, scopes: tuple) -> str:
    """A key listing without the Swift sources of module scopes a pass did not execute."""
    if not scopes:
        return listing
    prefixes = tuple(scope["path"].rstrip("/") + "/" for scope in scopes)
    return "".join(line + "\n" for line in listing.splitlines()
                   if not ((path := line.split("\t", 1)[1]).endswith(".swift") and path.startswith(prefixes)))


def _scope_name(scope: dict) -> str:
    return scope.get("module") or scope["testTarget"]


def module_surface(root: Path, tree: str, scope: dict) -> Optional[str]:
    """The hash of a module scope's printed package and public interface at `tree`, or None
    when it is unproven: no sources, a failed compile, or a construct the interface omits.

    Body-only changes keep the surface, so clients compile and behave identically unless
    they run the module's own (coverage-counted) code. Results are cached per source listing.
    A UI test target is a bundle nothing links: it has no surface, only selection.
    """
    if "testTarget" in scope:
        return "test-target"
    listing = _git(root, "ls-tree", "-r", "--full-tree", tree, "--", scope["path"])
    sources = [(line.split()[2], line.split("\t", 1)[1]) for line in listing.splitlines() if line.endswith(".swift")]
    if not sources:
        return None
    # The proof rules live in this file, so a cached verdict holds only for the code that made it.
    identity = hashlib.sha256(json.dumps([scope, listing, _key_extra("xcode"),
                                          hashlib.sha256(Path(__file__).read_bytes()).hexdigest()],
                                         sort_keys=True).encode()).hexdigest()
    cache = _common_dir(root) / "work" / "gate" / "surfaces" / f"{identity}.json"
    with contextlib.suppress(OSError, ValueError, KeyError):
        return json.loads(cache.read_text())["surface"]
    surface, reason = None, ""
    with tempfile.TemporaryDirectory(prefix="gate-surface-") as temporary:
        files = []
        for index, (blob, path) in enumerate(sources):
            target = Path(temporary) / f"{index}-{Path(path).name}"
            target.write_bytes(subprocess.run(["git", "cat-file", "blob", blob], cwd=root, capture_output=True,
                                              check=True).stdout)
            files.append(str(target))
        text = "".join(Path(file).read_text(errors="replace") for file in files)
        sdk = subprocess.run(["xcrun", "--sdk", scope["sdk"], "--show-sdk-path"], capture_output=True, text=True)
        out = Path(temporary) / "out"
        try:
            built = sdk.returncode == 0 and subprocess.run(
                ["xcrun", "--sdk", scope["sdk"], "swiftc", "-parse-as-library", "-emit-module", "-enable-library-evolution",
                 "-module-name", scope["module"], "-sdk", sdk.stdout.strip(), *scope["swiftFlags"],
                 "-emit-module-interface-path", f"{out}.swiftinterface",
                 "-emit-package-module-interface-path", f"{out}.package.swiftinterface", "-o", f"{out}.swiftmodule", *files],
                capture_output=True, text=True, cwd=temporary, timeout=SURFACE_TIMEOUT_SECONDS).returncode == 0
            interface = "".join(line + "\n" for suffix in ("swiftinterface", "package.swiftinterface")
                                for line in Path(f"{out}.{suffix}").read_text().splitlines()
                                if not line.startswith("//")) if built else ""
        except (subprocess.TimeoutExpired, OSError):
            built, interface = False, ""
        if not built:
            reason = "the module did not compile on its own"
        elif _SOURCE_UNPROVEN.search(text):
            reason = "a source declares an Objective-C or symbol-level entry point"
        else:
            match = _SURFACE_UNPROVEN.search(interface)
            if match:
                reason = f"its interface has {match.group(0).strip()!r}"
            else:
                surface = hashlib.sha256(interface.encode()).hexdigest()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"surface": surface, "reason": reason, "module": scope["module"]}) + "\n")
    return surface


def scoped_keys(root: Path, change: Change, shard: Shard, context: dict) -> Dict[frozenset, Optional[str]]:
    """The key for each non-empty set of the step's module scopes a pass may not have executed."""
    scopes = shard.step.get("moduleScopes") or []
    subsets = [tuple(scope for bit, scope in enumerate(scopes) if mask >> bit & 1) for mask in range(1, 1 << len(scopes))]
    return {frozenset(_scope_name(scope) for scope in subset): cache_key(root, change, shard, context, subset)
            for subset in subsets}


def module_execution(shard: Shard, log: Path) -> Dict[str, Optional[bool]]:
    """Whether a passing shard ran each module scope's code, from the coverage report the
    shard's command names in its log (`iOS coverage: <json>`). None means unknown: no report,
    no covered line outside the scopes, or no instrumented file of that module. A UI test
    target runs exactly when the shard's `--only-testing` selectors name it."""
    scopes = shard.step.get("moduleScopes") or []
    reports = re.findall(r"^iOS coverage: (.+)$", log.read_text(errors="replace"), re.M) if log.exists() else []
    files: dict = {}
    with contextlib.suppress(OSError, ValueError, KeyError, IndexError):
        files = json.loads(Path(reports[-1]).read_text())["files"]
    # Every journey runs app code outside the scopes, so a report without any covered line
    # there lost its counters: then nothing is known.
    prefixes = tuple(scope["path"].rstrip("/") + "/" for scope in scopes)
    if not any(value.get("covered", 0) > 0 for path, value in files.items() if not path.startswith(prefixes)):
        files = {}
    words = shlex.split(shard.command)
    selected = {word.split("/")[0] for previous, word in zip(words, words[1:]) if previous == "--only-testing"}
    selected |= {word.split(":", 1)[1].split("/")[0] for word in words if word.startswith("--only-testing:")}
    result: Dict[str, Optional[bool]] = {}
    for scope in scopes:
        if "testTarget" in scope:
            # Without selectors the runner's default set decides, which the gate does not read.
            result[scope["testTarget"]] = (scope["testTarget"] in selected) if selected else None
            continue
        prefix = scope["path"].rstrip("/") + "/"
        owned = [value for path, value in files.items() if path.startswith(prefix) and value.get("executable", 0) > 0]
        result[scope["module"]] = None if not owned else any(value.get("covered", 0) > 0 for value in owned)
    return result


def reusable(root: Path, change: Change, shard: Shard, key: str, context: dict) -> Optional[dict]:
    """A valid pass under the full key, else under a key without module scopes it did not execute."""
    hit = cached(root, shard, key)
    if hit or not shard.step.get("moduleScopes"):
        return hit
    for scoped in scoped_keys(root, change, shard, context).values():
        hit = cached(root, shard, scoped) if scoped else None
        if hit:
            return hit
    return None


def _scoped_note(hit: dict) -> str:
    unexecuted = sorted(module for module, ran in (hit.get("moduleExecution") or {}).items() if ran is False)
    return f"; it ran none of {', '.join(unexecuted)}, whose surface is unchanged" if unexecuted else ""


def _result_path(root: Path, shard: Shard, key: str) -> Path:
    return _common_dir(root) / "work" / "gate" / "results" / shard.step["id"] / f"{key}.json"


def cached(root: Path, shard: Shard, key: str) -> Optional[dict]:
    path = _result_path(root, shard, key)
    if not path.exists():
        return None
    with contextlib.suppress(ValueError, OSError):
        record = json.loads(path.read_text())
        # A pass excused by quarantine holds only while every excused test is still quarantined.
        excused = record.get("quarantined") or []
        if excused and not set(excused) <= set(flakes.active(_common_dir(root))):
            return None
        if record.get("outcome") == "pass" and all((root / a).exists() for a in shard.step.get("artifacts", [])):
            return record
    return None


# ---------------------------------------------------------------- running

_UDID = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
CPU_WINDOW_SECONDS = 10.0


def _cpu_seconds(text: str) -> float:
    """ps `time` (user + system), as [[D-]H:]M:SS.ss."""
    total = 0.0
    for part in text.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


class _Tree:
    """A step's process tree: every process ever seen descending from its shell.

    Members are keyed by pid and start time, so a reused pid is never taken for one. A
    process that starts its own session or process group (the iOS lease holder's command,
    xcodebuild under ios-test-process.py) leaves the step's group but not this tree, and
    stays in it after its parent dies and launchd adopts it (#1071). A process that detaches
    and loses its parent between two samples (SAMPLE_SECONDS) is not seen.

    The tree also measures the step's CPU (#1083): every member's accumulated CPU time, plus
    the processes of a simulator a member names by UDID (they run under launchd_sim, outside
    the tree, and are observed only: the iOS tooling, not the gate, shuts its simulator
    down). `peak_cores` is the busiest CPU_WINDOW_SECONDS window.
    """

    def __init__(self, root: int):
        self.root = root
        self.members: Dict[int, str] = {}
        self.seeded = False
        self.cpu: Dict[tuple, float] = {}
        self.udids: set = set()
        self.history: List[tuple] = []
        self.peak_cores = 0.0

    @property
    def cpu_seconds(self) -> float:
        return sum(self.cpu.values())

    def sample(self) -> Dict[int, int]:
        """Refresh the members; returns the live ones (zombies excluded) with their RSS in KB."""
        done = subprocess.run(["ps", "-axo", "pid=,ppid=,stat=,rss=,time=,lstart=,args="], capture_output=True, text=True)
        rows: Dict[int, tuple] = {}
        for line in done.stdout.splitlines():
            parts = line.split(None, 10)
            if len(parts) >= 10 and parts[0].isdigit() and parts[1].isdigit() and parts[3].isdigit():
                with contextlib.suppress(ValueError):
                    rows[int(parts[0])] = (int(parts[1]), parts[2], int(parts[3]), " ".join(parts[5:10]),
                                           _cpu_seconds(parts[4]), parts[10] if len(parts) > 10 else "")
        self.members = {pid: start for pid, start in self.members.items() if pid in rows and rows[pid][3] == start}
        if not self.seeded and self.root in rows:
            self.members[self.root], self.seeded = rows[self.root][3], True
        grown = True
        while grown:
            grown = False
            for pid, (ppid, _, _, start, _, _) in rows.items():
                if ppid in self.members and pid not in self.members:
                    self.members[pid], grown = start, True
        self._measure(rows)
        return {pid: rows[pid][2] for pid in self.members if not rows[pid][1].startswith("Z")}

    def _measure(self, rows: Dict[int, tuple]) -> None:
        for pid in self.members:
            # xcodebuild names its simulator as `-destination ...id=<UDID>`; simctl takes it as an argument.
            if "id=" in rows[pid][5] or "simctl" in rows[pid][5]:
                self.udids.update(_UDID.findall(rows[pid][5]))
        observed = set(self.members)
        if self.udids:
            simulators = {pid for pid, row in rows.items() if row[5].startswith("launchd_sim")
                          and any(f"Devices/{udid}/" in row[5] for udid in self.udids)}
            grown = bool(simulators)
            while grown:
                grown = False
                for pid, row in rows.items():
                    if row[0] in simulators and pid not in simulators:
                        simulators.add(pid)
                        grown = True
            observed |= simulators
        for pid in observed:
            # Every observed process started after the step did, so all its CPU time is the step's.
            self.cpu[(pid, rows[pid][3])] = rows[pid][4]
        now, total = time.monotonic(), self.cpu_seconds
        self.history.append((now, total))
        while len(self.history) > 2 and now - self.history[1][0] >= CPU_WINDOW_SECONDS:
            self.history.pop(0)
        start, before = self.history[0]
        if now - start >= CPU_WINDOW_SECONDS * 0.5:
            self.peak_cores = max(self.peak_cores, (total - before) / (now - start))

    @staticmethod
    def _signal(pids, signum: int) -> None:
        # Members by pid, never the root's group id: once the root is reaped that id can be reused.
        for pid in pids:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signum)

    def stop(self, grace: float) -> str:
        """End the whole tree: TERM every member, give their handlers `grace` seconds to
        finish (the iOS lease holder joins its command and releases its simulator lane;
        anything that starts meanwhile is joined too), then KILL whatever is left.
        Returns a line for the step log, empty when nothing was running."""
        live = self.sample()
        if not live:
            return ""
        started, count = time.monotonic(), len(live)
        self._signal(live, signal.SIGTERM)
        while live and time.monotonic() - started < grace:
            time.sleep(0.2)
            live = self.sample()
        if not live:
            return f"gate: stopped the step's {count} processes in {time.monotonic() - started:.1f}s"
        stubborn = sorted(live)
        self._signal(live, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while live and time.monotonic() < deadline:
            time.sleep(0.1)
            live = self.sample()
        line = (f"gate: stopped the step's processes; {len(stubborn)} still running {grace:g}s after SIGTERM "
                f"were killed: {' '.join(map(str, stubborn))}")
        if live:
            line += f"\ngate: WARNING {len(live)} processes survived SIGKILL: {' '.join(map(str, sorted(live)))}"
        return line


def _host_used_mb() -> int:
    """Physical memory in use on the host: total minus what heavy.available_mb() counts as available."""
    return heavy._total_mb() - heavy.available_mb()


def _check_environment() -> Dict[str, str]:
    """The environment every step runs with: variables pointing at a live Tron home are dropped."""
    policy = Path(__file__).resolve().parents[2] / "packages" / "gateway" / "src" / "tron-home-environment-policy.mjs"
    try:
        done = subprocess.run(["node", str(policy)], capture_output=True, text=True)
    except OSError as error:
        raise GateError(f"cannot run the Tron-home environment preflight: {error}") from error
    if done.returncode != 0:
        raise GateError(done.stderr.strip() or "inherited environment resolves into a live Tron home")
    dropped = set(done.stdout.split())
    return {name: value for name, value in os.environ.items() if name not in dropped}


@dataclass
class Outcome:
    shard: Shard
    outcome: str  # pass | fail | timeout | cancelled
    exit_code: int
    seconds: float
    peak_rss_mb: int
    cpu_seconds: float
    log: Optional[Path]
    peak_cores: float = 0.0
    queued_seconds: float = 0.0
    failed_tests: List[str] = field(default_factory=list)
    failure_class: Optional[str] = None


def _last_line(log: Path) -> str:
    with contextlib.suppress(OSError):
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 2048))
            lines = [line for line in stream.read().decode(errors="replace").splitlines() if line.strip()]
            return lines[-1][:140] if lines else ""
    return ""


def run_shard(root: Path, prelude: str, shard: Shard, log: Path, environment: Dict[str, str], position: str,
              print_line=print, stop: Optional[threading.Event] = None, job: Optional[heavy.Job] = None) -> Outcome:
    step = shard.step
    stop = stop or threading.Event()
    log.parent.mkdir(parents=True, exist_ok=True)
    lease = None
    queued = time.monotonic()
    # Dedicated hosted VMs do not share this Mac's queue. Membership is checked
    # before executing any step; local-only steps cannot take this path.
    if step["class"] == "heavy" and os.environ.get("GITHUB_ACTIONS") != "true":
        try:
            lease = heavy.acquire(f"gate {shard.name} in {root.name}", shard.command, need_mb=int(step["expectedRssMb"]),
                                  cancelled=stop.is_set, cores=float(step.get("expectedCores") or heavy.DEFAULT_CORES),
                                  cores_min=step.get("coresMin"), pool=step.get("pool"), job=job)
        except heavy.Cancelled:
            return Outcome(shard, "cancelled", 130, 0.0, 0, 0.0, log, queued_seconds=round(time.monotonic() - queued, 1))
    env = dict(environment)
    if lease:
        env.update(lease.environment())
    # A report left by an earlier run must not name this run's failures.
    report = flakes._vitest_report(root, shard.command)
    if report:
        report.unlink(missing_ok=True)
    # Time in the queue is not the step's: its budget and hard limit start here.
    started = time.monotonic()
    queued_seconds = round(started - queued, 1)
    peak = 0
    # Xcode builds and simulators do their work in launchd-owned services outside the
    # step's process group, so their tree RSS undercounts; these steps also sample the
    # host's memory in use above its level at start (an upper bound when others run).
    host_sampling = step.get("memorySample") == "host"
    host_base = _host_used_mb() if host_sampling else 0
    host_peak = 0
    timed_out = False
    cancelled = False
    try:
        with log.open("w") as stream:
            stream.write(f"$ {shard.command}\n")
            stream.flush()
            process = subprocess.Popen(["bash", "-c", f"set -eo pipefail\n{prelude}\n{shard.command}"], cwd=root, env=env,
                                       stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True, pass_fds=(lease.fd,) if lease else ())
            tree = _Tree(process.pid)
            tree.sample()
            done = threading.Event()
            result: dict = {}

            def wait() -> None:
                _, status, usage = os.wait4(process.pid, 0)
                result["status"], result["usage"] = status, usage
                done.set()

            waiter = threading.Thread(target=wait, daemon=True)
            waiter.start()
            next_beat = started + HEARTBEAT_SECONDS
            try:
                while not done.wait(SAMPLE_SECONDS):
                    now = time.monotonic()
                    peak = max(peak, sum(tree.sample().values()))
                    if host_sampling:
                        host_peak = max(host_peak, _host_used_mb() - host_base)
                    if stop.is_set():
                        cancelled = True
                        break
                    if now - started > step["timeoutSeconds"]:
                        timed_out = True
                        break
                    if now >= next_beat:
                        next_beat = now + HEARTBEAT_SECONDS
                        over = " OVER BUDGET" if now - started > step["budgetSeconds"] else ""
                        print_line(f"gate: {position} {shard.name} running {now - started:.0f}s (budget {step['budgetSeconds']}s, "
                                   f"limit {step['timeoutSeconds']}s, rss {peak // 1024} MB, cpu peak {tree.peak_cores:.1f} cores)"
                                   f"{over} | {_last_line(log)}", flush=True)
            finally:
                # A step owns its whole process tree, whether it timed out, was cancelled or
                # passed: anything it left running goes with it, after its own cleanup ran.
                stopped = tree.stop(STOP_GRACE_SECONDS)
                if stopped:
                    stream.write(f"\n{stopped}\n")
                done.wait(10)
    finally:
        if lease:
            lease.release()
    seconds = round(time.monotonic() - started, 1)
    usage = result.get("usage")
    # Reaped children are in rusage; sampling adds what detached or ran in a simulator.
    cpu = round(max(usage.ru_utime + usage.ru_stime if usage else 0.0, tree.cpu_seconds), 1)
    # A step shorter than half a CPU window has no window peak; its average is its peak.
    cores = round(tree.peak_cores or cpu / max(seconds, 0.1), 1)
    # Sampling misses very short steps; the largest single process (bytes on macOS) is a floor.
    peak = max(peak, (usage.ru_maxrss // 1024) if usage else 0, host_peak * 1024)
    status = result.get("status", -1)
    code = os.waitstatus_to_exitcode(status) if status != -1 else 124
    if cancelled:
        return Outcome(shard, "cancelled", 130, seconds, peak // 1024, cpu, log, cores, queued_seconds)
    if timed_out:
        with log.open("a") as stream:
            stream.write(f"\ngate: TIMEOUT {shard.name} exceeded its hard limit of {step['timeoutSeconds']}s "
                         f"(after {queued_seconds}s in the heavy queue, which does not count)\n")
        return Outcome(shard, "timeout", 124, seconds, peak // 1024, cpu, log, cores, queued_seconds)
    return Outcome(shard, "pass" if code == 0 else "fail", code, seconds, peak // 1024, cpu, log, cores, queued_seconds)


def _excerpt(log: Path) -> str:
    lines = log.read_text(errors="replace").splitlines()[-EXCERPT_LINES:]
    return "\n".join(f"    {line}" for line in lines)


def _record(root: Path, change: Change, key: str, outcome: Outcome, classify: bool = False,
            context: Optional[dict] = None) -> None:
    entry = {**ledger.context(root), "step": outcome.shard.step["id"], "shard": outcome.shard.name,
             "outcome": outcome.outcome, "exit": outcome.exit_code, "seconds": outcome.seconds,
             "peakRssMb": outcome.peak_rss_mb, "cpuSeconds": outcome.cpu_seconds, "key": key, "tree": change.tree,
             "head": _git(root, "rev-parse", "HEAD").strip(), "worktree": root.name, "class": outcome.shard.step["class"],
             "tier": outcome.shard.tier, "queuedSeconds": outcome.queued_seconds, "peakCores": outcome.peak_cores,
             **({"failureClass": outcome.failure_class, "failedTests": outcome.failed_tests} if outcome.failure_class else {}),
             **({"classifyRerun": True} if classify else {}),
             **({"testSeconds": tested} if outcome.shard.step["id"] == "ios.journeys"
                and (tested := flakes.test_seconds(outcome.log)) else {}),
             "loadAtEnd": round(os.getloadavg()[0], 1)}
    base = _common_dir(root) / "work" / "gate"
    ledger.append(base / "metrics.jsonl", entry)
    if outcome.outcome == "pass":
        path = _result_path(root, outcome.shard, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        record = {**entry, "command": outcome.shard.command, "log": str(outcome.log)}
        path.write_text(json.dumps(record, indent=2) + "\n")
        # A pass that ran none of a module's code also holds under the key without that
        # module's sources while its surface is unchanged (README.md#module-scoped-journeys).
        executed = module_execution(outcome.shard, outcome.log) if context else {}
        unexecuted = frozenset(module for module, ran in executed.items() if ran is False)
        scoped = scoped_keys(root, change, outcome.shard, context).get(unexecuted) if unexecuted else None
        if scoped:
            path = _result_path(root, outcome.shard, scoped)
            path.write_text(json.dumps({**record, "moduleExecution": executed, "fullKey": key}, indent=2) + "\n")


# The counts of the last `execute` in this process, for the land ledger (land.py), and the
# shard that stopped it (the post-merge check bisects on it, mainline.py).
LAST_RUN: Dict[str, int] = {}
FAILED_SHARD: Optional[Shard] = None


def execute(root: Path, config: dict, shards: List[Shard], change: Change, *, force: bool = False,
            only_first_pending: bool = False, require_clean: bool = False,
            verification_context: Optional[dict] = None) -> bool:
    """`_execute`, with one row per gate run in `runs.jsonl`: its shards, how many ran and how many
    were reused, and whether it passed (`gate report` derives the reuse rate from it)."""
    started = time.monotonic()
    ok: Optional[bool] = None
    # The run is one heavy-queue job: its first heavy shard takes a host-wide job slot,
    # which it keeps until the run ends (heavy.py).
    job = heavy.Job(f"gate in {root.name}")
    try:
        ok = _execute(root, config, shards, change, job, force=force, only_first_pending=only_first_pending,
                      require_clean=require_clean, verification_context=verification_context)
        return ok
    finally:
        job.release()
        with contextlib.suppress(GateError, OSError):
            ledger.append(_common_dir(root) / "work" / "gate" / "runs.jsonl", {
                **ledger.context(root), "head": _git(root, "rev-parse", "HEAD").strip(), "tree": change.tree,
                "worktree": root.name, "mode": "next" if only_first_pending else "run", "ok": ok,
                "seconds": round(time.monotonic() - started, 1), **LAST_RUN})


def _execute(root: Path, config: dict, shards: List[Shard], change: Change, job: heavy.Job, *, force: bool,
             only_first_pending: bool, require_clean: bool, verification_context: Optional[dict]) -> bool:
    """Run shards in catalog order, reusing valid passes; stop at the first failure. True when all pass.

    Steps run one after another. Up to `parallelShards` pending shards of one step
    run together, each admitted by the heavy queue on its own memory and CPU; the first
    failing shard stops its siblings.
    """
    environment = _check_environment()
    # Diagnostic probes check historical source with the range's loaded verifier.
    # Their passes must name that policy, never the verifier bytes in the probe tree.
    context = verification_context if verification_context is not None else _verification_context(root, change, config)
    prelude = context["prelude"]
    head = _git(root, "rev-parse", "HEAD").strip()
    logs = _git_dir(root) / "work" / "logs" / head[:12]
    total = len(shards)
    started = time.monotonic()
    global FAILED_SHARD
    FAILED_SHARD = None
    counts = LAST_RUN
    counts.clear()
    counts.update(ran=0, reused=0, shards=total)
    print(f"gate: {total} shards for {head[:12]} (tree {change.tree[:12]}) against {change.base_ref}", flush=True)
    groups: List[List[tuple]] = []
    for number, shard in enumerate(shards, 1):
        if groups and groups[-1][0][1].step is shard.step:
            groups[-1].append((number, shard))
        else:
            groups.append([(number, shard)])
    finished: set = set()
    classified: set = set()
    for group in groups:
        # A group is re-examined after a failure is settled (excused by quarantine or
        # classified as a flake), so siblings it stopped run; each key is classified once.
        while True:
            pending = []
            for number, shard in group:
                key = cache_key(root, change, shard, context)
                if key in finished:
                    continue
                hit = None if force else reusable(root, change, shard, key, context)
                if hit:
                    finished.add(key)
                    counts["reused"] += 1
                    print(f"gate: [{number}/{total}] {shard.name}: reused pass from {hit['at']} ({hit['seconds']}s)"
                          f"{_scoped_note(hit)}", flush=True)
                else:
                    pending.append((number, shard, key))
            if not pending:
                break
            if only_first_pending and counts["ran"]:
                print(f"gate: next pending is {pending[0][1].name}; stopping after one step (gate next)", flush=True)
                return False
            step = pending[0][1].step
            # At most `parallelShards` shards of one step run together (each still admitted by
            # memory); serial suites leave it unset, so timing-sensitive tests never share the host.
            width = 1 if only_first_pending else max(1, int(step.get("parallelShards") or 1))
            failed = None
            for batch in [pending[i:i + width] for i in range(0, len(pending), width)]:
                failed = _run_batch(root, prelude, batch, logs, environment, total, change, counts, job, finished,
                                    context)
                if failed or only_first_pending:
                    break
            if failed:
                number, shard, outcome, key = failed
                if key in classified or not _settle(root, prelude, shard, key, outcome, logs, environment, total,
                                                    change, counts, job, finished, number):
                    FAILED_SHARD = shard
                    print(f"\n--- {shard.name} failed: {shard.command}\n{_excerpt(outcome.log)}\n"
                          f"gate: stopped at {shard.name}; {total - number} later shards not started. "
                          f"Fix it and rerun: passing shards whose inputs did not change are reused.", flush=True)
                    return False
                classified.add(key)
                continue
            if only_first_pending:
                break
        if require_clean and (_git(root, "rev-parse", "HEAD").strip() != head or workspace_tree(root) != change.tree):
            raise GateError("the head or the worktree changed while steps ran; rerun on a stable tree")
        if only_first_pending and counts["ran"]:
            remaining = sum(1 for g in groups[groups.index(group) + 1:] for _ in g) + len(pending) - 1
            if remaining:
                print(f"gate: one step run; {remaining} shards may remain (gate next again, or gate run)", flush=True)
                return True
    print(f"gate: all {total} shards passed ({counts['ran']} ran, {counts['reused']} reused) in "
          f"{time.monotonic() - started:.0f}s", flush=True)
    return True


def _settle(root: Path, prelude: str, shard: Shard, key: str, outcome: Outcome, logs: Path,
            environment: Dict[str, str], total: int, change: Change, counts: dict, job: Optional[heavy.Job],
            finished: set, number: int) -> bool:
    """Whether a failed shard may still pass the gate (README.md#flakes). Never a retry to green:

    - failures that are all quarantined (active, owned) pass, listed;
    - a timeout, or a failure of a test with flake evidence, gets one isolated rerun to classify
      it. If it passes, named tests are quarantined today with an owner issue, and a timeout
      with no failing test is recorded as `infra` (load, for admission);
    - anything else, or a rerun that fails again, stops the gate.
    """
    common = _common_dir(root)
    tests = outcome.failed_tests
    quarantined = flakes.active(common)
    if outcome.outcome == "fail" and tests and set(tests) <= set(quarantined):
        owners = ", ".join(sorted({f"#{quarantined[t]['issue']}" for t in tests}))
        print(f"gate: QUARANTINED {shard.name}: its only failures are quarantined ({owners}); they ran and are "
              f"recorded:\n" + "\n".join(f"    {t} (until {quarantined[t]['until']})" for t in tests), flush=True)
        path = _result_path(root, shard, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"outcome": "pass", "quarantined": tests, "at": ledger.now(), "seconds": outcome.seconds,
                                    "command": shard.command, "log": str(outcome.log)}, indent=2) + "\n")
        finished.add(key)
        return True
    suspect = outcome.outcome == "timeout" or bool(set(tests) & flakes.flake_history(common))
    if not suspect:
        return False
    position = f"[{number}/{total}]"
    print(f"gate: {position} {shard.name}: {outcome.failure_class} failure"
          f"{' of a test with flake evidence' if outcome.outcome != 'timeout' else ''}; one isolated rerun to "
          f"classify it (it does not make a failure pass)", flush=True)
    log = Path(str(outcome.log).replace(".log", ".classify.log"))
    rerun = run_shard(root, prelude, shard, log, environment, position, job=job)
    _classify(root, rerun)
    _record(root, change, key, rerun, classify=True)
    counts["ran"] += 1
    if rerun.outcome != "pass":
        print(f"gate: {position} {shard.name}: failed again on the isolated rerun ({rerun.failure_class}); a real failure",
              flush=True)
        return False
    finished.add(key)
    if tests:
        owned = flakes.quarantine(root, common, shard.step["id"], tests, outcome.log)
        owner = f"#{owned['issue']}" if owned["issue"] else "NO OWNER (filing failed; file one and run gate quarantine add)"
        print(f"gate: FLAKY {shard.name}: failed, then passed alone on the same key. Quarantined until {owned['until']}, "
              f"owner {owner}:\n" + "\n".join(f"    {t}" for t in tests), flush=True)
    else:
        print(f"gate: INFRA {shard.name}: timed out with no failing test, then passed alone; recorded as load, not code "
              f"(gate report lists it for admission)", flush=True)
    return True


def _classify(root: Path, outcome: Outcome) -> None:
    if outcome.outcome in ("fail", "timeout"):
        outcome.failed_tests = flakes.failed_tests(root, outcome.shard.command, outcome.log)
        outcome.failure_class = flakes.failure_class(outcome.outcome, outcome.failed_tests)


def _run_batch(root: Path, prelude: str, batch: list, logs: Path, environment: Dict[str, str], total: int,
               change: Change, counts: dict, job: Optional[heavy.Job] = None,
               finished: Optional[set] = None, context: Optional[dict] = None) -> Optional[tuple]:
    """Run shards together; return (number, shard, outcome) of the first failure, else None."""
    stop = threading.Event()
    lock = threading.Lock()
    failures: List[tuple] = []
    finished = finished if finished is not None else set()

    def one(number: int, shard: Shard, key: str) -> None:
        step = shard.step
        position = f"[{number}/{total}]"
        log = logs / (re.sub(r"[^\w.#-]+", "_", shard.name) + ".log")
        print(f"gate: {position} {shard.name} ({step['class']}, budget {step['budgetSeconds']}s, "
              f"limit {step['timeoutSeconds']}s) log: {log}", flush=True)
        outcome = run_shard(root, prelude, shard, log, environment, position, stop=stop, job=job)
        _classify(root, outcome)
        _record(root, change, key, outcome, context=context)
        with lock:
            counts["ran"] += 1
            if outcome.outcome == "pass":
                finished.add(key)
            if outcome.outcome == "cancelled":
                print(f"gate: {position} {shard.name}: stopped; step cleanup joined", flush=True)
                return
            verdict = {"pass": "pass", "fail": f"FAIL (exit {outcome.exit_code})", "timeout": "TIMEOUT"}[outcome.outcome]
            over = " (over budget)" if outcome.seconds > step["budgetSeconds"] else ""
            queued = f" after {outcome.queued_seconds:.0f}s queued" if outcome.queued_seconds >= 1 else ""
            print(f"gate: {position} {shard.name}: {verdict} in {outcome.seconds}s{over}{queued}, peak rss "
                  f"{outcome.peak_rss_mb} MB, cpu {outcome.cpu_seconds}s (peak {outcome.peak_cores} cores)", flush=True)
            if outcome.outcome != "pass":
                failures.append((number, shard, outcome, key))
                stop.set()

    interrupted = False

    def request_stop(_signal, _frame) -> None:
        # Never raise inside Thread.join: cleanup belongs to the worker until it joins.
        nonlocal interrupted
        interrupted = True

    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {sig: signal.signal(sig, request_stop) for sig in signals}
    threads = [threading.Thread(target=one, args=item) for item in batch]
    try:
        for thread in threads:
            thread.start()
        while any(thread.is_alive() for thread in threads):
            if interrupted and not stop.is_set():
                print("gate: cancellation requested; joining step cleanup", flush=True)
                stop.set()
            for thread in threads:
                thread.join(0.1)
    finally:
        stop.set()
        # The step owns the bounded TERM/KILL grace. A shorter join would abandon it.
        for thread in threads:
            if thread.ident is not None:
                thread.join()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if interrupted:
        raise KeyboardInterrupt
    return min(failures, key=lambda item: item[0]) if failures else None


# ---------------------------------------------------------------- entry points used by work land

def branch_check(root: Path, config: dict, tests: List[str], base_ref: str) -> Optional[dict]:
    """The landing gate (README.md#landing): the branch's own plan on its clean commit, run
    outside any landing lock. A pass records a receipt keyed by the exact tree; a later
    landing of the same tree whose plan those passes still cover reuses it without running
    anything. Returns the receipt (with `reused`), or None when a shard failed."""
    import mainline
    dirty = _git(root, "status", "--porcelain", "--untracked-files=all").splitlines()
    if dirty:
        raise GateError("commit or remove local changes first; the landing gate checks a commit:\n  " + "\n  ".join(dirty[:20]))
    catalog = load_catalog()
    change = change_for(root, base_ref, tests)
    shards = plan(catalog, change)
    context = _verification_context(root, change, config)
    keys = [(shard, cache_key(root, change, shard, context)) for shard in shards]
    held = mainline.receipt(root, change.tree)
    if held:
        covered = {check["key"] for check in held["checks"]}
        if all(key in covered and reusable(root, change, shard, key, context) for shard, key in keys):
            print(f"gate: receipt for tree {change.tree[:12]} from {held['at']} covers all {len(keys)} shards; "
                  "nothing to run", flush=True)
            return {**held, "reused": True}
    if not execute(root, config, shards, change, require_clean=True):
        return None
    return {**_receipt(root, change, keys), "reused": False}


def _receipt(root: Path, change: Change, keys: list) -> dict:
    import mainline
    checks = [{"shard": shard.name, "key": key} for shard, key in keys]
    return mainline.record_receipt(root, change.tree, _git(root, "rev-parse", "HEAD").strip(), change.merge_base, checks)


def _config(root: Path) -> dict:
    return json.loads((root / ".github" / "work.json").read_text())


def _base_ref(root: Path, config: dict, given: Optional[str]) -> str:
    if given:
        return given
    return f"{config['claim']['remote']}/{config['claim']['baseBranch']}"


def _print_plan(shards: List[Shard], change: Change, root: Path, as_json: bool) -> None:
    rows = []
    context = _verification_context(root, change, _config(root))
    for shard in shards:
        key = cache_key(root, change, shard, context)
        hit = reusable(root, change, shard, key, context)
        rows.append({"shard": shard.name, "class": shard.step["class"], "budgetSeconds": shard.step["budgetSeconds"],
                     "timeoutSeconds": shard.step["timeoutSeconds"], "expectedRssMb": shard.step["expectedRssMb"],
                     "expectedCores": shard.step.get("expectedCores"),
                     "status": "reusable pass" if hit else "pending", "command": shard.command})
    if as_json:
        print(json.dumps({"base": change.base_ref, "mergeBase": change.merge_base, "tree": change.tree,
                          "changed": change.paths, "plan": rows}, indent=2))
        return
    print(f"gate plan: {len(change.paths)} changed paths against {change.base_ref} (merge base {change.merge_base[:12]})")
    for number, row in enumerate(rows, 1):
        print(f"  {number:>2}. {row['shard']:<40} {row['class']:<5} budget {row['budgetSeconds']:>3}s  "
              f"rss~{row['expectedRssMb']:>5} MB  {row['expectedCores'] or '-':>4} cores  {row['status']}")


def window_report(root: Path, since: str, until: Optional[str], exclude: List[str], as_json: bool,
                  as_digest: bool = False) -> int:
    import report as reporting
    now = datetime.now(timezone.utc)
    summary = reporting.build(root, load_catalog()["steps"], reporting.parse_time(since, now),
                              reporting.parse_time(until, now) if until else now, exclude,
                              heavy_events=heavy._directory() / "events.jsonl")
    print(json.dumps(summary, indent=2) if as_json else reporting.digest(summary) if as_digest else reporting.render(summary))
    return 0


def report(root: Path, as_json: bool) -> int:
    path = _common_dir(root) / "work" / "gate" / "metrics.jsonl"
    rows: Dict[str, List[dict]] = {}
    for line in path.read_text().splitlines() if path.exists() else []:
        with contextlib.suppress(ValueError):
            entry = json.loads(line)
            rows.setdefault(entry["shard"], []).append(entry)
    catalog = {step["id"]: step for step in load_catalog()["steps"]}
    summary = []
    for shard, entries in sorted(rows.items()):
        seconds = [e["seconds"] for e in entries]
        rss = [e["peakRssMb"] for e in entries]
        # Peak cores are recorded since #1083; older rows have none.
        cores = [e["peakCores"] for e in entries if "peakCores" in e] or [0.0]
        step = catalog.get(entries[0]["step"], {})
        summary.append({"shard": shard, "runs": len(entries), "passes": sum(e["outcome"] == "pass" for e in entries),
                        "medianSeconds": statistics.median(seconds), "maxSeconds": max(seconds),
                        "medianPeakRssMb": statistics.median(rss), "maxPeakRssMb": max(rss),
                        "medianPeakCores": statistics.median(cores), "maxPeakCores": max(cores),
                        "budgetSeconds": step.get("budgetSeconds"), "expectedRssMb": step.get("expectedRssMb"),
                        "expectedCores": step.get("expectedCores")})
    if as_json:
        print(json.dumps(summary, indent=2))
        return 0
    print(f"{'shard':<44} runs  median   max   budget  rss med/max (expected)  cores med/max (expected)")
    for row in summary:
        print(f"{row['shard']:<44} {row['runs']:>4} {row['medianSeconds']:>6.0f}s {row['maxSeconds']:>5.0f}s "
              f"{row['budgetSeconds'] or 0:>6}s  {row['medianPeakRssMb']:>5.0f}/{row['maxPeakRssMb']:<5.0f} ({row['expectedRssMb']})"
              f"  {row['medianPeakCores']:>4.1f}/{row['maxPeakCores']:<4.1f} ({row['expectedCores'] or '-'})")
    return 0


def catalog_table() -> int:
    catalog = load_catalog()
    for step in catalog["steps"]:
        trigger = step["trigger"]
        when = "always" if trigger.get("always") else ", ".join(trigger.get("paths", [])) or f"select:{trigger.get('select')}"
        shards = f" x{step['shards']}" if step.get("shards") else ""
        commands = step.get("shardCommands") or {"": step["command"]}
        runs = "\n".join(f"    run{(' [' + label + ']') if label else ''}:  {command}" for label, command in commands.items())
        print(f"{step['id']:<26} {step['class']:<5} budget {step['budgetSeconds']:>3}s limit {step['timeoutSeconds']:>3}s "
              f"rss~{step['expectedRssMb']:>5} MB {step.get('expectedCores', '-')} cores"
              f"{(' (min ' + str(step['coresMin']) + ')') if 'coresMin' in step else ''}{(' pool ' + step['pool']) if step.get('pool') else ''}"
              f"{shards}  unlocks {step['unlocks']}\n    when: {when}\n{runs}")
    return 0


# ---------------------------------------------------------------- background jobs

def _jobs_dir(root: Path) -> Path:
    return _common_dir(root) / "work" / "gate" / "jobs"


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _job(root: Path, job_id: str) -> dict:
    matches = sorted(_jobs_dir(root).glob(f"{job_id}*/job.json"))
    if len(matches) != 1:
        raise GateError(f"no single gate job matches {job_id}; see scripts/tron gate jobs")
    job = json.loads(matches[0].read_text())
    exit_file = matches[0].parent / "exit"
    cancelled = (matches[0].parent / "cancelled").exists()
    if exit_file.exists():
        job["exit"] = int(exit_file.read_text())
        job["state"] = "cancelled" if job["exit"] == 130 and cancelled else ("passed" if job["exit"] == 0 else "failed")
    elif cancelled and not job.get("runnerOwned"):
        job["state"] = "ended without a cleanup receipt"
    elif not _alive(job["pid"]):
        job["state"] = "ended without a result"
    else:
        job["state"] = "cancelling" if cancelled else "running"
    job["dir"] = str(matches[0].parent)
    return job


def submit(root: Path, argv: List[str]) -> int:
    """Hand a gate run to the background and return at once: the session keeps working.

    The job runs `gate run` detached in its own process group; heavy shards wait in the
    host queue as usual. `jobs` shows its live state, queue position and last line, `wait`
    returns its result to the requesting session and `cancel` stops it.
    """
    # A newer submit of the same run from the same worktree supersedes a pending one: its
    # passed shards are already recorded, and the new job reuses them on the newer tree.
    for path in sorted(_jobs_dir(root).glob("*/job.json")) if _jobs_dir(root).is_dir() else []:
        previous = _job(root, path.parent.name)
        if previous["state"] == "running" and previous["worktree"] == str(root) and previous["args"] == argv:
            cancel(root, previous["id"])
            print(f"gate: superseded job {previous['id']} (same run from this worktree)")
    job_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + f"-{os.getpid()}"
    directory = _jobs_dir(root) / job_id
    directory.mkdir(parents=True)
    output = directory / "output.log"
    # The runner, not a killable shell wrapper, owns both cleanup and its terminal receipt.
    with output.open("w") as stream:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_job", str(directory), *argv],
                                   cwd=root, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    # Publication by the child proves its signal handler is installed before submit returns.
    deadline = time.monotonic() + 10
    while not (directory / "job.json").exists():
        if process.poll() is not None:
            raise GateError(f"job {job_id} failed to start; see {output}")
        if time.monotonic() >= deadline:
            process.terminate()
            process.wait()
            raise GateError(f"job {job_id} did not publish its owner; see {output}")
        time.sleep(0.02)
    print(f"gate: submitted job {job_id} (pid {process.pid}); keep working.\n"
          f"  progress: scripts/tron gate jobs\n  result:   scripts/tron gate wait {job_id}\n"
          f"  cancel:   scripts/tron gate cancel {job_id}")
    return 0


def jobs(root: Path) -> int:
    directory = _jobs_dir(root)
    queued = {item.get("pid"): position for position, item in enumerate(heavy.waiters(heavy._directory()), 1)}
    for path in sorted(directory.glob("*/job.json")) if directory.is_dir() else []:
        job = _job(root, path.parent.name)
        if job["state"] not in ("running", "cancelling") and job["worktree"] != str(root):
            continue
        output = Path(job["dir"]) / "output.log"
        last = _last_line(output)
        # Heavy tickets belong to this runner (or an owned nested command).
        position = next((f", heavy queue #{n}" for pid, n in queued.items() if pid and _parent_chain(pid, job["pid"])), "")
        print(f"{job['id']}  {job['state']}{position}  {Path(job['worktree']).name}  {' '.join(job['args']) or '(plan)'}\n    {last}")
    return 0


def _parent_chain(pid: int, ancestor: int) -> bool:
    for _ in range(6):
        if pid == ancestor:
            return True
        done = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
        if not done.stdout.strip():
            return False
        pid = int(done.stdout.strip())
    return False


def wait(root: Path, job_id: str) -> int:
    job = _job(root, job_id)
    output = Path(job["dir"]) / "output.log"
    printed = 0
    while job["state"] in ("running", "cancelling"):
        time.sleep(1)
        text = output.read_text(errors="replace") if output.exists() else ""
        if len(text) > printed:
            print(text[printed:], end="", flush=True)
            printed = len(text)
        job = _job(root, job_id)
    text = output.read_text(errors="replace") if output.exists() else ""
    print(text[printed:], end="")
    print(f"gate: job {job['id']} {job['state']}")
    return int(job.get("exit", 1))


def cancel(root: Path, job_id: str) -> int:
    job = _job(root, job_id)
    if job["state"] != "running":
        print(f"gate: job {job['id']} already {job['state']}")
        return 0
    if not job.get("runnerOwned"):
        raise GateError("job predates runner-owned cancellation; wait for it or cancel with its original gate revision")
    (Path(job["dir"]) / "cancelled").touch()
    # A group TERM can kill ps mid-sample and lose the separate step tree (#1130).
    # Only the runner receives the request; its workers own process-tree cleanup.
    with contextlib.suppress(ProcessLookupError):
        os.kill(job["pid"], signal.SIGTERM)
    print(f"gate: cancellation requested for job {job['id']}")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="tron gate", description="Deterministic gated verification (tools/work/README.md#gate)")
    commands = parser.add_subparsers(dest="action", required=True)
    for name, help_text in (("plan", "print the ordered steps this change needs"),
                            ("run", "run the plan, or the named steps, reusing valid passes"),
                            ("next", "run only the next step without a valid pass")):
        sub = commands.add_parser(name, help=help_text)
        sub.add_argument("--base", help="base ref (default: the configured remote base, e.g. origin/main)")
        sub.add_argument("--tests", action="append", default=[], metavar="CMD", help="an integration or E2E journey to gate")
        if name == "plan":
            sub.add_argument("--json", action="store_true")
        if name == "run":
            sub.add_argument("steps", nargs="*", help="step ids or shard names (default: the whole plan)")
            sub.add_argument("--force", action="store_true", help="rerun even shards with a valid cached pass")
    commands.add_parser("submit", help="hand `gate run [args]` to the background and return at once")
    commands.add_parser("jobs", help="background gate jobs with live state and heavy-queue position")
    for name in ("wait", "cancel"):
        commands.add_parser(name, help=f"{name} a background gate job").add_argument("job")
    sub = commands.add_parser("report", help="wall time and peak RSS per shard; with --since, the window digest")
    formats = sub.add_mutually_exclusive_group()
    formats.add_argument("--json", action="store_true")
    formats.add_argument("--digest", action="store_true", help="one line from the requested --since window")
    sub.add_argument("--since", help="window start: ISO time or a span back from now (90m, 12h, 3d)")
    sub.add_argument("--until", help="window end (default now)")
    sub.add_argument("--exclude-worktree", action="append", default=[], metavar="GLOB",
                     help="leave out rows from worktrees whose name matches (legacy unmarked benchmark rows)")
    sub = commands.add_parser("quarantine", help="list, add or remove quarantined tests (README.md#flakes)")
    sub.add_argument("quarantine_action", choices=("list", "add", "remove"))
    sub.add_argument("test", nargs="?")
    sub.add_argument("--issue", type=int, help="owner issue (required for add)")
    sub.add_argument("--days", type=int, default=flakes.QUARANTINE_DAYS)
    sub = commands.add_parser("status", help="the post-merge check of main: current step, merges covered, last main that passed")
    sub.add_argument("--json", action="store_true")
    sub = commands.add_parser("build-source", help="select the passed main revision, or explicit task-branch HEAD")
    sub.add_argument("--require-current", action="store_true", help="refuse unless this checkout is the selected source")
    sub = commands.add_parser("main-check", help="check main since the last main that passed (land starts it)")
    sub.add_argument("--runner-fd", type=int, help=argparse.SUPPRESS)
    sub = commands.add_parser("catalog", help="print the step catalog")
    sub.add_argument("--ci", action="store_true", help="print the catalog's stable hosted CI step names")
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["submit"]:
        # `submit` forwards everything after it to `gate run`, including option-leading
        # arguments such as `--tests` (#1047). Validate them as `run` arguments now so a
        # bad invocation fails here instead of inside the detached job.
        forwarded = argv[2:] if argv[1:2] == ["--"] else argv[1:]
        parser.parse_args(["run", *forwarded])
        return submit(Path(_git(Path.cwd(), "rev-parse", "--show-toplevel").strip()), forwarded)
    args = parser.parse_args(argv)
    root = Path(_git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    try:
        if args.action == "report":
            if args.since:
                return window_report(root, args.since, args.until, args.exclude_worktree, args.json, args.digest)
            if args.digest:
                parser.error("--digest requires --since")
            return report(root, args.json)
        if args.action == "catalog":
            if args.ci:
                print(" ".join(load_catalog().get("ciSteps", [])))
                return 0
            return catalog_table()
        if args.action == "jobs":
            return jobs(root)
        if args.action in ("status", "main-check", "build-source"):
            import mainline
            if args.action == "build-source":
                try:
                    print(json.dumps(mainline.build_source(root, _config(root), args.require_current)))
                except mainline.MainlineError as error:
                    raise GateError(str(error)) from error
                return 0
            if args.action == "status":
                return mainline.status(root, _config(root), args.json)
            return mainline.run(root, _config(root), args.runner_fd)
        if args.action == "quarantine":
            return flakes.command(root, _common_dir(root), args.quarantine_action,
                                  args.test, args.issue, args.days)
        if args.action == "wait":
            return wait(root, args.job)
        if args.action == "cancel":
            return cancel(root, args.job)
        config = _config(root)
        catalog = load_catalog()
        change = change_for(root, _base_ref(root, config, args.base), args.tests)
        shards = plan(catalog, change)
        if args.action == "plan":
            _print_plan(shards, change, root, args.json)
            return 0
        if args.action == "run" and args.steps:
            shards = _named(catalog, change, shards, args.steps)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            unsafe = [s.name for s in shards if s.step.get("hosted") != "safe"]
            if unsafe:
                raise GateError("local-only steps cannot run on hosted CI: " + ", ".join(unsafe))
        ok = execute(root, config, shards, change, force=getattr(args, "force", False), only_first_pending=args.action == "next")
        # A whole-plan pass of a committed tree is the branch's receipt; `work land` reuses it.
        if ok and args.action == "run" and not args.steps and change.tree == _git(root, "rev-parse", "HEAD^{tree}").strip():
            context = _verification_context(root, change, config)
            _receipt(root, change, [(shard, cache_key(root, change, shard, context)) for shard in shards])
        return 0 if ok else 1
    except GateError as error:
        print(f"gate: {error}", file=sys.stderr)
        return 2


def _named(catalog: dict, change: Change, planned: List[Shard], names: List[str]) -> List[Shard]:
    """Named steps and their transitive prerequisites, including in shallow CI checkouts."""
    steps = {step["id"]: step for step in catalog["steps"]}
    wanted: List[Shard] = []
    visiting: set = set()

    def include(name: str) -> None:
        if name in visiting:
            raise GateError(f"cyclic gate prerequisite: {name}")
        visiting.add(name)
        matched = [s for s in planned if s.name == name or s.step["id"] == name]
        if not matched:
            step = steps.get(name.split("#")[0].split("[")[0])
            if not step:
                raise GateError(f"no step or shard named {name}; see scripts/tron gate catalog")
            selections = [""]
            if "select" in step["trigger"]:
                selections = _select(step["trigger"]["select"], change, change.paths) or [""]
            matched = [s for s in expand(step, change, selections) if s.name == name or s.step["id"] == name]
            if not matched:
                raise GateError(f"no shard named {name}; see scripts/tron gate plan")
        for prerequisite in matched[0].step.get("after", []):
            include(prerequisite)
        wanted.extend(s for s in matched if s not in wanted)
        visiting.remove(name)

    for name in names:
        include(name)
    order = {step["id"]: i for i, step in enumerate(catalog["steps"])}
    return sorted(wanted, key=lambda shard: (order[shard.step["id"]], shard.index))


def _terminate(_signal, _frame) -> None:
    # Cancellation (gate cancel, a closed terminal): unwind so the running step's tree is stopped.
    raise KeyboardInterrupt


if __name__ == "__main__":
    for received in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(received, _terminate)
    argv = sys.argv[1:]
    result_path = None
    if argv and argv[0] == "_job":
        result_path = Path(argv[1]) / "exit"
        argv = ["run", *argv[2:]]
    code = 1
    try:
        if result_path:
            directory = result_path.parent
            temporary = directory / "job.tmp"
            temporary.write_text(json.dumps({
                "id": directory.name, "pid": os.getpid(), "runnerOwned": True,
                "worktree": str(Path.cwd().resolve()),
                "session": os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID") or "",
                "args": argv[1:], "submittedAt": datetime.now(timezone.utc).isoformat(timespec="seconds")}, indent=2) + "\n")
            temporary.replace(directory / "job.json")
        code = main(argv)
    except KeyboardInterrupt:
        print("gate: interrupted; the running step was stopped", file=sys.stderr)
        code = 130
    finally:
        if result_path:
            temporary = result_path.with_suffix(".tmp")
            temporary.write_text(f"{code}\n")
            temporary.replace(result_path)
    sys.exit(code)
