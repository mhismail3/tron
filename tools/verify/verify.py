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
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import ownership  # noqa: E402  (the one ownership authority)
sys.path.insert(0, str(ROOT / "tools" / "layers"))
import swift_index  # noqa: E402  (the one authority on a fresh iOS index and build stamp)

GATEWAY = "packages/gateway"
# A change here reaches everything above it, so it selects every lock (plan §6.2.2).
WIDENING_LAYERS = {"L0", "L1", "L2"}
WIDENING_MODULES = {"gateway/package", "gateway/test-support", "gateway/pi-sdk"}
# Locks not named `*.lock.integration.test.ts`: the Pi SDK seam's behavior trace and corpus.
NAMED_LOCKS = {f"{GATEWAY}/src/sessions/sdk-behavior-trace.integration.test.ts",
               f"{GATEWAY}/src/sessions/pi-persisted-state-corpus.integration.test.ts"}
SKIPPABLE = ("ios", "mac", "relay")
IOS = "packages/ios-app"
# The UIValidation test plan's targets, which scripts/tron-ios-test builds and runs. The Gateway E2E
# and profiling targets have their own lanes (scripts/ios-gateway-e2e-test, scripts/tron-profile ios).
IOS_TARGETS = {"UITests": "TronMobileUITests", "SwiftAppUITests": "TronSwiftAppUITests"}
# UIValidation journey classes that need a fixture only their harness provides; they run in its lane.
IOS_HARNESSED = {"RealGatewayPairAndChatUITests": "scripts/ios-gateway-e2e-test",
                 "TronMacTerminalUITests": "scripts/ios-mac-terminal-journey"}
NOT_DRIVEN = ("ios-lanes", "mac", "relay")


class VerifyError(Exception):
    pass


def git(*args: str) -> str:
    done = subprocess.run(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args], capture_output=True, text=True)
    if done.returncode:
        raise VerifyError(done.stderr.strip() or f"git {args[0]} failed")
    return done.stdout


def require_gateway_compiler() -> None:
    """npm must resolve this checkout's pinned compiler, never a global tsc."""
    gateway = ROOT / GATEWAY
    hint = f"prepare this worktree with: scripts/tron-node exec npm --prefix {GATEWAY} ci --include=dev"
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
    def listed(config: str, name: str) -> set:
        path = ROOT / GATEWAY / config
        if not path.exists():
            return set()
        text = path.read_text()
        block = re.search(name + r"\s*=\s*\[(.*?)\]", text, re.S)
        return {f"{GATEWAY}/{entry}" for entry in re.findall(r'"([^"]+)"', block.group(1))} if block else set()
    return listed("vitest.nested.config.ts", "nestedTestFiles"), listed("vitest.mac-terminal.config.ts", "macTerminalTestFiles")


def runner_of(path: str, nested: set, mac_terminal: set) -> str:
    if path.startswith(f"{GATEWAY}/src/"):
        return "mac" if path in mac_terminal else ("gateway-nested" if path in nested else "gateway")
    if path.endswith(".test.mjs"):
        return "node-gateway" if path.startswith(f"{GATEWAY}/") else "node"
    if path.endswith(".py"):
        return "python"
    if path.endswith(".sh"):
        return "shell"
    if path.startswith(f"{IOS}/"):
        return "ios" if path.split("/")[2] in IOS_TARGETS and ios_class(path) not in IOS_HARNESSED else "ios-lanes"
    if path.startswith("packages/mac-app/"):
        return "mac"
    if path.startswith("packages/push-relay/"):
        return "relay"
    raise VerifyError(f"no runner for test {path}")


def ios_class(path: str) -> str | None:
    """The XCTestCase class one iOS test file runs as: the class it is named for, else the class it extends."""
    stem, text = Path(path).stem, (ROOT / path).read_text()
    if re.search(rf"\bclass {re.escape(stem)}\b", text):
        return stem
    extended = re.search(r"^extension (\w+Tests)\b", text, re.M)
    return extended.group(1) if extended else None


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
        if all(path.startswith(("scripts/test-", "scripts/verify-")) and path.endswith(".py") for path in arguments):
            files = set(arguments)
    elif prefix == ["scripts/tron", "test", "gateway"] and arguments:
        if all(path.endswith(".test.mjs") or (path.startswith("src/") and path.endswith(".test.ts")) for path in arguments):
            files = {f"{GATEWAY}/{path}" for path in arguments}
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


def select(mode: str, target: str | None, base: str, modules: dict, tracked: list, paths: list | None = None) -> dict:
    """The tests a run selects; `paths` stands in for the changed paths (the mutation sampler's one file)."""
    owner = {path: key for key, module in modules.items() for path in module["owned"]}
    tests = [path for path in tracked if is_test(path)]
    locks = sorted(path for path in tests if is_lock(path))
    reasons: list[str] = []
    declared: set[str] = set()
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
        docs = [path for path in touched if is_doc(path)]
        if docs:
            reasons.append(f"{len(docs)} Markdown file(s): the documentation checks cover them; they select no test")
        code = [path for path in touched if not is_doc(path)]
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
                owned = [path for path in owned if path in changes[key] or (goldens and is_lock(path))]
                reasons.append(f"{key}: changes only its tests{' and goldens' if goldens else ''}; those {len(owned)} test file(s)")
            else:
                reasons.append(f"{key}: owns a changed path; its {len(owned)} owned test file(s)")
            selected |= set(owned)
    if mode in ("changed", "module"):
        # Reverse closure: modules that declare a dependency or a dynamic edge on a selected one.
        reached = frontier = chosen - narrow
        while frontier:
            dependents = {key for key, module in modules.items() if key not in reached
                          and (set(module.get("dependsOn", [])) | set(module.get("dynamicTargets", []))) & frontier}
            for key in sorted(dependents):
                dependent_locks = [path for path in modules[key]["owned"] if is_test(path) and is_lock(path)]
                selected |= set(dependent_locks)
                reasons.append(f"{key}: depends on a selected module; its {len(dependent_locks)} lock file(s)")
            reached, frontier = reached | dependents, dependents
        chosen |= reached
        # Risk belongs to the changed producer, not every consumer in the reverse closure.
        # Consumer locks still run now; unrelated global locks run once in the next batch.
        if mode == "changed":
            for key in sorted(set(changes) - narrow):
                module = modules.get(key)
                if module is None:
                    full_reasons.append(f"deleted module {key}")
                    continue
                risk = json.loads((ROOT / module["manifest"]).read_text()).get("riskClass", [])
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
        # Retired owners still seed consumers/full risk above, but only live
        # modules own verification commands that can execute now.
        declared |= (chosen - narrow) & modules.keys()
    for key in sorted(declared):
        external = set()
        for command in modules[key].get("verify", []):
            external |= declared_files(command, tracked)
        if external:
            selected |= external
            reasons.append(f"{key}: declared verification ({len(external)} test file(s))")
    if mode == "changed":
        nested, _ = nested_files()
        golden_owners = {owner[path] for path in touched if is_golden(path) and path in owner}
        immediate = {path for path in selected if owner.get(path) in narrow
                     or (is_lock(path) and owner.get(path) in golden_owners)}
        deferred = (selected & nested) - set(touched) - immediate
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
    docs_only = mode == "changed" and all(is_doc(path) for path in touched)
    # Generated doc blocks are built from Markdown, manifests and Gateway sources (tools/docs/README.md).
    doc_inputs = mode == "all" or any(is_doc(path) or path.endswith(".module.json") for path in touched)
    tier = "none" if docs_only else "full" if mode == "all" or full_reasons else "partial"
    return {"mode": mode, "base": base, "modules": sorted(chosen), "touched": len(touched), "paths": touched,
            "tier": tier, "fullReasons": full_reasons, "batchTests": sorted(batch_tests), "deferredTests": sorted(deferred), "reasons": reasons,
            "tests": sorted(selected), "docsOnly": docs_only, "docInputs": doc_inputs}


# ---------------------------------------------------------------------------- steps

class Run:
    def __init__(self, sha: str, total: int):
        self.sha, self.total, self.index, self.steps = sha, total, 0, []
        self.logs = ROOT / "test-results" / "verify" / sha
        self.logs.mkdir(parents=True, exist_ok=True)
        self.on_update = lambda: None

    def step(self, name: str, command: list[str] | str, cwd: Path = ROOT, count=None, env: dict | None = None,
             advisory: bool = False, accept=(0,)) -> dict:
        self.index += 1
        label = f"[{self.index}/{self.total}] {name}"
        started = time.time()
        log = self.logs / f"{self.index:02d}-{re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')}.log"
        print(f"{label} … (live log: {log.relative_to(ROOT)})", flush=True)
        result = {"name": name, "status": "running", "command": command, "cwd": str(cwd.relative_to(ROOT)),
                  "tests": None, "seconds": 0, "log": str(log.relative_to(ROOT))}
        self.steps.append(result)
        self.on_update()
        interrupted = False
        with log.open("w") as stream:
            process = subprocess.Popen(command, cwd=cwd, shell=isinstance(command, str), stdout=stream,
                                       stderr=subprocess.STDOUT, env={**os.environ, **(env or {})}, start_new_session=True)
            try:
                code = process.wait()
            except KeyboardInterrupt:
                interrupted = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 130
        output = log.read_text(errors="replace")
        ok = code in accept and not interrupted
        tests = count(output) if count and ok else None
        status = "interrupted" if interrupted else "ok" if ok else ("advisory" if advisory else "failed")
        seconds = round(time.time() - started, 1)
        result.update(status=status, exit=code, tests=tests, seconds=seconds)
        self.on_update()
        print(f"{label} {status.upper()} in {seconds}s" + (f" — {tests} passing test(s)" if tests is not None else ""), flush=True)
        if status != "ok":
            tail = output.strip().splitlines()[-(1 if advisory else 25):]
            print("\n".join(f"    {line}" for line in tail), flush=True)
            print(f"    full log: {result['log']}", flush=True)
        if interrupted:
            raise KeyboardInterrupt
        return result

    def reused(self, name: str, detail: str, command: list[str]) -> None:
        """A step whose evidence already exists for this commit; it compares equal to running it (exit 0)."""
        self.index += 1
        print(f"[{self.index}/{self.total}] {name} OK — {detail}", flush=True)
        self.steps.append({"name": name, "status": "ok", "exit": 0, "tests": None, "seconds": 0, "detail": detail,
                           "command": command, "cwd": "."})
        self.on_update()

    def skipped(self, name: str, reason: str) -> None:
        self.index += 1
        print(f"[{self.index}/{self.total}] {name} SKIPPED — {reason}", flush=True)
        self.steps.append({"name": name, "status": "skipped", "reason": reason, "tests": None, "seconds": 0})
        self.on_update()


def known_failures() -> dict[str, dict]:
    """One exact-case registry; invalid or expired entries cannot waive any check."""
    path = ROOT / "tools/verify/known-failures.json"
    try:
        if path.stat().st_size > 128 * 1024:
            raise ValueError("registry exceeds 128 KiB")
        entries = json.loads(path.read_text())
        if not isinstance(entries, list) or len(entries) > 100:
            raise ValueError("expected an array of at most 100 entries")
        known = {}
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"testId", "evidence", "issue", "expires"}:
                raise ValueError("each entry needs testId, evidence, issue and expires")
            identity, evidence = entry["testId"], entry["evidence"]
            if not isinstance(identity, str) or "::" not in identity:
                raise ValueError("testId must be a repository-relative test path::full case name")
            file, case = identity.split("::", 1)
            if not file.startswith(f"{GATEWAY}/src/") or not file.endswith(".test.ts") or ".." in Path(file).parts or not case.strip() or not (ROOT / file).is_file():
                raise ValueError(f"invalid testId: {identity}")
            if identity in known:
                raise ValueError(f"duplicate testId: {identity}")
            if type(entry["issue"]) is not int or entry["issue"] <= 0 or not isinstance(evidence, dict) or set(evidence) != {"command", "commit", "failureDigest"}:
                raise ValueError(f"missing owner issue or failing evidence: {identity}")
            if not isinstance(evidence["command"], str) or not evidence["command"].strip() or not isinstance(evidence["commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", evidence["commit"]):
                raise ValueError(f"invalid failing command/commit: {identity}")
            if not isinstance(evidence["failureDigest"], str) or not re.fullmatch(r"[0-9a-f]{64}", evidence["failureDigest"]):
                raise ValueError(f"invalid failureDigest: {identity}")
            git("merge-base", "--is-ancestor", evidence["commit"], "HEAD")
            expiry = date.fromisoformat(entry["expires"])
            if expiry.isoformat() != entry["expires"] or expiry <= datetime.now(timezone.utc).date():
                raise ValueError(f"expired quarantine: {identity} (expiry {entry['expires']}, issue #{entry['issue']})")
            known[identity] = entry
        return known
    except (OSError, ValueError, TypeError, VerifyError) as error:
        raise VerifyError(f"known-failures: {error}") from error


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


def vitest_count(output_path: Path):
    def count(_output: str):
        # A missing report counts zero, which fails the group: vitest must have written it this run.
        try:
            return json.loads(output_path.read_text()).get("numPassedTests", 0)
        except (OSError, ValueError):
            return 0  # missing or truncated: no evidence
    return count


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


def test_spec(group: str, files: list[str], selectors: list[str], logs: Path):
    """One command definition shared by planning and execution."""
    node = [str(ROOT / "scripts/tron-node"), "exec"]
    if group in ("gateway", "gateway-nested"):
        report = logs / f"{group}-vitest.json"
        config = ["--config", "vitest.nested.config.ts"] if group == "gateway-nested" else []
        return (["python3", str(ROOT / "tools/verify/gateway.py"), *config, "--reporter=default", "--reporter=json",
                        f"--outputFile.json={report}", *[path[len(GATEWAY) + 1:] for path in files]],
                ROOT / GATEWAY, vitest_count(report))
    if group == "ios":
        return ([str(ROOT / "scripts/tron-ios-test"), "run", *[arg for owner in selectors for arg in ("--only-testing", owner)]], ROOT, ios_count)
    if group == "node-gateway":
        return (node + ["node", "--test", "--test-concurrency=1", *[p[len(GATEWAY) + 1:] for p in files]], ROOT / GATEWAY, tap_count)
    if group == "node":
        return (node + ["node", "--test", "--test-concurrency=1", *files], ROOT, tap_count)
    if group == "python":
        return (per_file("python3", files), ROOT, python_count)
    return (per_file("bash", files), ROOT, lambda _out: len(files))


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
    args = parser.parse_args(argv)
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
    except (VerifyError, ownership.GitError) as error:
        print(f"verify: {error}", file=sys.stderr)
        return 2

    try:
        known = known_failures()
    except VerifyError as error:
        print(f"verify: {error}", file=sys.stderr)
        return 1
    nested, mac_terminal = nested_files()
    groups: dict[str, list[str]] = {}
    try:
        for path in selection["tests"]:
            groups.setdefault(runner_of(path, nested, mac_terminal), []).append(path)
        # Selectors are needed only by a run that drives the iOS group (#1522).
        selectors = ios_selectors(groups.get("ios", [])) if "ios" not in skip else []
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
    for group, files in sorted(groups.items()):
        print(f"  {group}: {len(files)} file(s){' (skipped by --skip)' if skipped_group(group) else ''}", flush=True)
    plan_steps = ["ownership", "budgets", "documentation policy", "generated docs", "agent policy", "privacy guard", "git diff --check",
                  "moved-lines (advisory)"] \
        + (["gateway typecheck", "gateway lint", "layers gateway"] if gateway_touched else []) \
        + (["ios build"] if ios_lane else []) + ["layers ios"] \
        + [f"tests: {group}" for group in sorted(groups)]
    tron = str(ROOT / "scripts/tron")
    ios_test = str(ROOT / "scripts/tron-ios-test")
    node = [str(ROOT / "scripts/tron-node"), "exec"]
    checks = [
        ("ownership", [tron, "ownership"], {}),
        ("budgets", [tron, "budgets", "HEAD", "--base", base], {}),
        ("documentation policy", ["python3", "scripts/check-documentation-policy.py"], {}),
        ("generated docs", [tron, "docs", "check", "--base", base] if selection["docInputs"] or gateway_touched else None, {}),
        ("agent policy", ["bash", "scripts/check-agent-policy.sh"], {}),
        ("privacy guard", f"git diff {base}..HEAD | scripts/personal-info-guard.sh --stdin", {}),
        ("git diff --check", ["git", "diff", "--check", f"{base}..HEAD"], {}),
        ("moved-lines (advisory)", [tron, "measure", base, sha], {"advisory": True}),
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
            commands.append({"name": "ios build", "command": [ios_test, "build"], "reuse": "only if current build stamp is fresh"})
        commands.append({"name": "layers ios", "command": [tron, "layers", "ios", "--base", base], "requires": "fresh iOS index"})
        for group, files in sorted(groups.items()):
            if group in NOT_DRIVEN or skipped_group(group):
                commands.append({"name": f"tests: {group}", "notRun": "explicit skip" if skipped_group(group) else "requires owning harness"})
            else:
                command, cwd, _ = test_spec(group, files, selectors, ROOT / "test-results/verify" / sha)
                commands.append({"name": f"tests: {group}", "command": command, "cwd": str(cwd.relative_to(ROOT))})
        deferred_commands = []
        if selection["deferredTests"]:
            command, cwd, _ = test_spec("gateway-nested", selection["deferredTests"], [], ROOT / "test-results/verify" / sha)
            deferred_commands.append({"name": "tests: gateway-nested", "command": command, "cwd": str(cwd.relative_to(ROOT))})
        print(json.dumps({"selection": selection, "groups": groups, "steps": plan_steps, "commands": commands,
                          "deferredCommands": deferred_commands, "batchCommand": [tron, "verify", "--batch"] if selection["tier"] == "full" else None}, indent=2))
        return 0

    # Worktree creation deliberately does not install dependencies. Refuse before
    # any checks (including generated docs) can use an absent/stale install or PATH tsc.
    if gateway_touched:
        try:
            require_gateway_compiler()
        except VerifyError as error:
            print(f"verify: {error}", file=sys.stderr)
            return 2

    run = Run(sha, len(plan_steps))
    report_path = ROOT / "test-results" / "verify" / f"{sha}.json"

    def finish(verdict: str, message: str, announce: bool = True) -> int:
        quarantined = [entry for step in run.steps for entry in step.get("quarantined", [])]
        if verdict == "passed" and quarantined:
            verdict = "quarantined"
            message += f"; {len(quarantined)} known failure(s), NOT an unqualified pass"
        comparable = {"commit": sha, "selection": selection, "steps": [{k: v for k, v in step.items() if k not in ("seconds", "log", "detail")} for step in run.steps], "verdict": verdict}
        report = {"schema": "tron.verify.v1", "commit": sha, "verdict": verdict, "message": message,
                  "resultDigest": hashlib.sha256(json.dumps(comparable, sort_keys=True).encode()).hexdigest(),
                  "selection": selection, "groups": groups, "skipped": sorted(skip), "steps": run.steps,
                  "passingTests": sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))}
        temporary = report_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, report_path)
        if announce:
            print(f"verify: {verdict.upper()} — {message}", flush=True)
            print(f"verify: report {report_path.relative_to(ROOT)} (result digest {report['resultDigest'][:16]})", flush=True)
        return 0 if verdict in ("passed", "quarantined") else 1

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
        # The iOS reference check reads the index of this commit's own test build (plan §6.7, #1459). The iOS
        # lane builds it when the stamp is stale; a selection without iOS reports it skipped, never passed.
        stale = ios_index_stale()
        if ios_lane:
            if stale is None:
                run.reused("ios build", "the test products are already stamped for this commit", [ios_test, "build"])
            elif run.step("ios build", [ios_test, "build"])["status"] == "failed":
                return finish("failed", "ios build failed")
            stale = None
        if stale is not None:
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
            command, cwd, count = test_spec(group, files, selectors, run.logs)
            report = run.logs / f"{group}-vitest.json"
            report.unlink(missing_ok=True)
            env = {"TEST_RUNNER_TRON_UPDATE_LOCKS": args.update_locks} if group == "ios" and args.update_locks else update
            result = run.step(label, command, cwd=cwd, count=count, env=env)
            if group in ("gateway", "gateway-nested") and result["status"] == "failed":
                failed, complete = gateway_failures(report, (ROOT / result["log"]).read_text(errors="replace"))
                result["failedTests"] = list(failed)
                print("\n".join(f"    failed: {identity}" for identity in failed), flush=True)
                if result["exit"] == 1 and complete and all(identity in known and digest == known[identity]["evidence"]["failureDigest"] for identity, digest in failed.items()):
                    result.update(status="quarantined", tests=count(""), quarantined=[
                        {"testId": identity, "expires": known[identity]["expires"], "issue": known[identity]["issue"]} for identity in failed])
                    for entry in result["quarantined"]:
                        print(f"    QUARANTINED: {entry['testId']} — expires {entry['expires']}, issue #{entry['issue']}", flush=True)
                    run.on_update()
            elif group == "ios":
                if result["status"] == "failed":
                    result["failedTests"] = ios_failures((ROOT / result["log"]).read_text(errors="replace"))
                    print("\n".join(f"    failed: {name}" for name in result["failedTests"]), flush=True)
            if result["status"] == "failed":
                return finish("failed", f"{label} failed")
            if not result.get("tests") and not result.get("quarantined"):
                result["status"] = "failed"
                return finish("failed", f"{label} ran zero passing tests: an empty group is not evidence")
        passing = sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))
        if not_run:
            return finish("incomplete", f"selected tests were not run: {', '.join(not_run)} (pass --skip to accept explicitly)")
        if passing == 0 and selection["docsOnly"]:
            return finish("passed", "Empty or Markdown-only change: static/documentation checks are its evidence")
        if passing == 0 and selection["deferredTests"]:
            return finish("passed", f"affected static checks passed; {len(selection['deferredTests'])} serial test file(s) deferred; full batch is not green")
        if passing == 0 and not any(step.get("quarantined") for step in run.steps):
            return finish("failed", "zero tests ran: an empty selection is not evidence")
        groups_run = len([step for step in run.steps if step["name"].startswith("tests:") and step["status"] == "ok"])
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
