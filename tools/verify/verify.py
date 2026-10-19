#!/usr/bin/env python3
"""scripts/tron verify: static checks plus the tests each manifest selects (tools/verify/README.md)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools" / "ownership"))
import ownership  # noqa: E402  (the one ownership authority)

GATEWAY = "packages/gateway"
# A change here reaches everything above it, so it selects every lock (plan §6.2.2).
WIDENING_LAYERS = {"L0", "L1", "L2"}
WIDENING_MODULES = {"gateway/package", "gateway/test-support", "gateway/pi-sdk"}
# Locks not named `*.lock.integration.test.ts`: the Pi SDK seam's behavior trace and corpus.
NAMED_LOCKS = {f"{GATEWAY}/src/sessions/sdk-behavior-trace.integration.test.ts",
               f"{GATEWAY}/src/sessions/pi-persisted-state-corpus.integration.test.ts"}
SKIPPABLE = ("ios", "mac", "relay")


class VerifyError(Exception):
    pass


def git(*args: str) -> str:
    done = subprocess.run(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args], capture_output=True, text=True)
    if done.returncode:
        raise VerifyError(done.stderr.strip() or f"git {args[0]} failed")
    return done.stdout


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
    if path.startswith("packages/ios-app/"):
        return "ios"
    if path.startswith("packages/mac-app/"):
        return "mac"
    if path.startswith("packages/push-relay/"):
        return "relay"
    raise VerifyError(f"no runner for test {path}")


# ---------------------------------------------------------------------------- selection

def select(mode: str, target: str | None, base: str, modules: dict, tracked: list, paths: list | None = None) -> dict:
    """The tests a run selects; `paths` stands in for the changed paths (the mutation sampler's one file)."""
    owner = {path: key for key, module in modules.items() for path in module["owned"]}
    tests = [path for path in tracked if is_test(path)]
    locks = sorted(path for path in tests if is_lock(path))
    reasons: list[str] = []
    selected: set[str] = set()
    if mode == "all":
        selected |= set(locks)
        reasons.append(f"--all: every lock ({len(locks)} files)")
        touched, chosen = ["(all)"], set()
    elif mode in ("module", "update-locks"):
        if target not in modules:
            raise VerifyError(f"no module {target!r}; see scripts/tron ownership --modules")
        chosen = {target}
        owned = [path for path in modules[target]["owned"] if is_test(path)]
        selected |= set(path for path in owned if mode == "module" or is_lock(path))
        reasons.append(f"--{mode} {target}: {'its owned tests' if mode == 'module' else 'its locks'} ({len(selected)} files)")
        touched = sorted(modules[target]["owned"])
    else:
        if paths is None:
            # -z keeps names exactly (no C quoting); a rename or copy record carries two paths.
            fields, names, i = git("diff", "--name-status", "-z", "-M", f"{base}...HEAD").split("\0"), set(), 0
            while i < len(fields) and fields[i]:
                width = 2 if fields[i][0] in "RC" else 1
                names.update(fields[i + 1:i + 1 + width])
                i += 1 + width
            touched = sorted(names)
        else:
            touched = sorted(paths)
        if not touched:
            raise VerifyError(f"no change between {base} and HEAD; use --module or --all")
        chosen = {owner[path] for path in touched if path in owner}
        unowned = [path for path in touched if path not in owner and path in tracked]
        # A deleted or renamed-away path is owned as of the base revision.
        gone = [path for path in touched if path not in tracked]
        if gone:
            base_modules = ownership.check(base)[0]["modules"]
            base_owner = {path: key for key, module in base_modules.items() for path in module["owned"]}
            chosen |= {base_owner[path] for path in gone if path in base_owner}
            unowned += [path for path in gone if path not in base_owner]
        for key in sorted(chosen):
            owned = [path for path in modules.get(key, {"owned": []})["owned"] if is_test(path)]
            selected |= set(owned)
            reasons.append(f"{key}: owns a changed path; its {len(owned)} owned test file(s)")
        # Reverse closure: modules that declare a dependency or a dynamic edge on a selected one.
        frontier = set(chosen)
        while frontier:
            dependents = {key for key, module in modules.items() if key not in chosen
                          and (set(module.get("dependsOn", [])) | set(module.get("dynamicTargets", []))) & frontier}
            for key in sorted(dependents):
                dependent_locks = [path for path in modules[key]["owned"] if is_test(path) and is_lock(path)]
                selected |= set(dependent_locks)
                reasons.append(f"{key}: depends on a selected module; its {len(dependent_locks)} lock file(s)")
            chosen |= dependents
            frontier = dependents
        widening = sorted(key for key in chosen if key in modules and (modules[key]["layer"] in WIDENING_LAYERS or key in WIDENING_MODULES))
        if widening or unowned:
            selected |= set(locks)
            why = ", ".join([f"{key} ({modules[key]['layer']})" for key in widening] + [f"unowned {path}" for path in unowned][:5])
            reasons.append(f"widened to every lock ({len(locks)} files): {why}")
    return {"mode": mode, "base": base, "modules": sorted(chosen), "touched": len(touched), "reasons": reasons,
            "tests": sorted(selected)}


# ---------------------------------------------------------------------------- steps

class Run:
    def __init__(self, sha: str, total: int):
        self.sha, self.total, self.index, self.steps = sha, total, 0, []
        self.logs = ROOT / "test-results" / "verify" / sha
        self.logs.mkdir(parents=True, exist_ok=True)

    def step(self, name: str, command: list[str] | str, cwd: Path = ROOT, count=None, env: dict | None = None,
             advisory: bool = False, accept=(0,)) -> dict:
        self.index += 1
        label = f"[{self.index}/{self.total}] {name}"
        print(f"{label} …", flush=True)
        started = time.time()
        log = self.logs / f"{self.index:02d}-{re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')}.log"
        with log.open("w") as stream:
            done = subprocess.run(command, cwd=cwd, shell=isinstance(command, str), stdout=stream, stderr=subprocess.STDOUT,
                                  env={**os.environ, **(env or {})})
        output = log.read_text(errors="replace")
        ok = done.returncode in accept
        tests = count(output) if count and ok else None
        status = "ok" if ok else ("advisory" if advisory else "failed")
        seconds = round(time.time() - started, 1)
        result = {"name": name, "status": status, "exit": done.returncode, "tests": tests, "seconds": seconds,
                  "log": str(log.relative_to(ROOT))}
        self.steps.append(result)
        print(f"{label} {status.upper()} in {seconds}s" + (f" — {tests} passing test(s)" if tests is not None else ""), flush=True)
        if status != "ok":
            tail = output.strip().splitlines()[-(1 if advisory else 25):]
            print("\n".join(f"    {line}" for line in tail), flush=True)
            print(f"    full log: {result['log']}", flush=True)
        return result

    def skipped(self, name: str, reason: str) -> None:
        self.index += 1
        print(f"[{self.index}/{self.total}] {name} SKIPPED — {reason}", flush=True)
        self.steps.append({"name": name, "status": "skipped", "reason": reason, "tests": None, "seconds": 0})


def vitest_count(output_path: Path):
    def count(_output: str):
        # A missing report counts zero, which fails the group: vitest must have written it this run.
        if not output_path.exists():
            return 0
        return json.loads(output_path.read_text()).get("numPassedTests", 0)
    return count


def tap_count(output: str) -> int:
    found = re.findall(r"^[#ℹ] pass (\d+)", output, re.M)
    return int(found[-1]) if found else 0


FILE_MARKER = "### verify file: "


def python_count(output: str) -> int:
    """A unittest file counts its `Ran N tests` (zero stays zero); a plain script that exits 0 counts once."""
    total = 0
    for segment in output.split(FILE_MARKER)[1:]:
        ran = re.findall(r"^Ran (\d+) tests?", segment, re.M)
        total += sum(int(n) for n in ran) if ran else 1
    return total


def per_file(interpreter: str, files: list[str]) -> str:
    return " && ".join(f"echo {shlex.quote(FILE_MARKER + path)} && {interpreter} {shlex.quote(path)}" for path in files)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron verify")
    mode = parser.add_mutually_exclusive_group(required=True)
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
        if git("status", "--porcelain", "--untracked-files=normal").strip():
            raise VerifyError("the worktree has uncommitted or untracked changes; verify reads the committed state, commit first")
        sha = git("rev-parse", "HEAD").strip()
        base = git("merge-base", args.base, "HEAD").strip() if name == "changed" else git("rev-parse", "--verify", args.base).strip()
        result, _ = ownership.check()  # violations fail the ownership step below
        modules = result["modules"]
        selection = select(name, args.module or args.update_locks, base, modules, result["tracked"])
    except (VerifyError, ownership.GitError) as error:
        print(f"verify: {error}", file=sys.stderr)
        return 2

    nested, mac_terminal = nested_files()
    groups: dict[str, list[str]] = {}
    try:
        for path in selection["tests"]:
            groups.setdefault(runner_of(path, nested, mac_terminal), []).append(path)
    except VerifyError as error:
        print(f"verify: {error}", file=sys.stderr)
        return 2
    gateway_touched = name == "all" or any(key.startswith("gateway/") for key in selection["modules"]) \
        or any(path.startswith(f"{GATEWAY}/") for path in selection["tests"])

    print(f"verify --{name}{' ' + (args.module or args.update_locks) if args.module or args.update_locks else ''} at {sha[:12]}"
          f" (base {base[:12]}): {len(selection['tests'])} test file(s) selected", flush=True)
    for reason in selection["reasons"]:
        print(f"  why: {reason}", flush=True)
    for group, files in sorted(groups.items()):
        print(f"  {group}: {len(files)} file(s){' (skipped by --skip)' if group in skip else ''}", flush=True)
    plan_steps = ["ownership", "budgets", "documentation policy", "privacy guard", "git diff --check", "ledger (advisory)"] \
        + (["gateway typecheck", "gateway lint", "layers gateway"] if gateway_touched else []) + ["layers ios"] \
        + [f"tests: {group}" for group in sorted(groups)]
    if args.plan:
        print(json.dumps({"selection": selection, "groups": groups, "steps": plan_steps}, indent=2))
        return 0

    run = Run(sha, len(plan_steps))
    report_path = ROOT / "test-results" / "verify" / f"{sha}.json"

    def finish(verdict: str, message: str) -> int:
        comparable = {"commit": sha, "selection": selection, "steps": [{k: v for k, v in step.items() if k not in ("seconds", "log")} for step in run.steps], "verdict": verdict}
        report = {"schema": "tron.verify.v1", "commit": sha, "verdict": verdict, "message": message,
                  "resultDigest": hashlib.sha256(json.dumps(comparable, sort_keys=True).encode()).hexdigest(),
                  "selection": selection, "groups": groups, "skipped": sorted(skip), "steps": run.steps,
                  "passingTests": sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))}
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"verify: {verdict.upper()} — {message}", flush=True)
        print(f"verify: report {report_path.relative_to(ROOT)} (result digest {report['resultDigest'][:16]})", flush=True)
        return 0 if verdict == "passed" else 1

    tron = str(ROOT / "scripts" / "tron")
    ios_reference_missing = False
    node = [str(ROOT / "scripts" / "tron-node"), "exec"]
    checks = [
        ("ownership", [tron, "ownership"], {}),
        ("budgets", [tron, "budgets", "HEAD", "--base", base], {}),
        ("documentation policy", ["python3", "scripts/check-documentation-policy.py"], {}),
        ("privacy guard", f"git diff {base}..HEAD | scripts/personal-info-guard.sh --stdin", {}),
        ("git diff --check", ["git", "diff", "--check", f"{base}..HEAD"], {}),
        ("ledger (advisory)", [tron, "work", "ledger"], {"advisory": True}),
    ]
    for label, command, options in checks:
        if run.step(label, command, **options)["status"] == "failed":
            return finish("failed", f"{label} failed")
    if gateway_touched:
        for label, command in (("gateway typecheck", node + ["npm", "run", "check"]), ("gateway lint", node + ["npm", "run", "lint"])):
            if run.step(label, command, cwd=ROOT / GATEWAY)["status"] == "failed":
                return finish("failed", f"{label} failed")
        if run.step("layers gateway", [tron, "layers", "gateway", "--base", base])["status"] == "failed":
            return finish("failed", "layers gateway failed")
    # The iOS reference check needs a fresh index from this commit's test build; without one it is
    # reported as skipped, never as passed (plan §6.7, #1459).
    ios = subprocess.run([tron, "layers", "ios", "--base", base], cwd=ROOT, capture_output=True, text=True)
    if ios.returncode == 2 and any(reason in ios.stderr for reason in (
            "stale index", "no readable build stamp", "has no index store", "covers no iOS source file")):
        run.skipped("layers ios", "no fresh iOS index for this commit (run scripts/tron-ios-test build)")
        if name == "all" or any(key.startswith("ios-app/") for key in selection["modules"]):
            ios_reference_missing = True
    elif run.step("layers ios", [tron, "layers", "ios", "--base", base])["status"] == "failed":
        return finish("failed", "layers ios failed")

    update = {"TRON_UPDATE_LOCKS": args.update_locks} if args.update_locks else {}
    not_run = ["ios (reference check)"] if ios_reference_missing and "ios" not in skip else []
    for group in sorted(groups):
        files = groups[group]
        label = f"tests: {group}"
        if group in skip:
            run.skipped(label, f"{len(files)} file(s) skipped by --skip {group}")
            continue
        if group in ("ios", "mac", "relay"):
            not_run.append(group)
            run.skipped(label, f"{len(files)} file(s) need the {group} lane, which verify does not drive; pass --skip {group} to accept")
            continue
        if group in ("gateway", "gateway-nested"):
            report = run.logs / f"{group}-vitest.json"
            report.unlink(missing_ok=True)
            config = ["--config", "vitest.nested.config.ts"] if group == "gateway-nested" else []
            relative = [path[len(GATEWAY) + 1:] for path in files]
            command = node + ["npx", "vitest", "run", *config, "--reporter=default", "--reporter=json",
                              f"--outputFile.json={report}", *relative]
            result = run.step(label, command, cwd=ROOT / GATEWAY, count=vitest_count(report), env=update)
            if result["status"] == "failed" and report.exists():
                failed = [f"{Path(suite['name']).name} > {test['fullName']}" for suite in json.loads(report.read_text()).get("testResults", [])
                          for test in suite.get("assertionResults", []) if test.get("status") == "failed"]
                result["failedTests"] = failed
                print("\n".join(f"    failed: {name}" for name in failed), flush=True)
        elif group == "node-gateway":
            result = run.step(label, node + ["node", "--test", "--test-concurrency=1", *[p[len(GATEWAY) + 1:] for p in files]],
                              cwd=ROOT / GATEWAY, count=tap_count)
        elif group == "node":
            result = run.step(label, node + ["node", "--test", "--test-concurrency=1", *files], count=tap_count)
        elif group == "python":
            result = run.step(label, per_file("python3", files), count=python_count)
        else:  # shell
            result = run.step(label, per_file("bash", files), count=lambda _out, n=len(files): n)
        if result["status"] == "failed":
            return finish("failed", f"{label} failed")
        if not result.get("tests"):
            result["status"] = "failed"
            return finish("failed", f"{label} ran zero passing tests: an empty group is not evidence")
    passing = sum(step.get("tests") or 0 for step in run.steps if step["name"].startswith("tests:"))
    if not_run:
        return finish("incomplete", f"selected tests were not run: {', '.join(not_run)} (pass --skip to accept explicitly)")
    if passing == 0:
        return finish("failed", "zero tests ran: an empty selection is not evidence")
    groups_run = len([step for step in run.steps if step["name"].startswith("tests:") and step["status"] == "ok"])
    return finish("passed", f"{passing} passing test(s) across {groups_run} runner group(s)"
                  + (f"; skipped by request: {', '.join(sorted(skip))}" if skip else ""))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
