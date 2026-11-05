#!/usr/bin/env python3
"""scripts/tron probe: remove or move one unit in a scratch worktree and see which checks go red.

A unit is a tracked file, a directory or a module id. The probe checks out HEAD in a private
worktree, runs the unit's guardians there once unchanged (baseline), applies the change (delete,
or `--move` without updating any caller), commits it and runs the same checks again. Guardians are
the tests `scripts/tron verify` selects for the unit plus the tests of every module whose files
name it (tools/ownership/cards.py), and the static `scripts/tron ownership` check. The verdict:

- precise: tests that passed now fail, and every failure's output names the unit;
- cascade: some failure never names the unit, so its reader cannot tell what broke;
- silent: no test fails. The unit is either dead (delete it) or unguarded (add a test that
  fails before and passes after). The static check is reported separately.

It measures and never gates; exit 0 after any verdict, 1 for a baseline that is not green, 2 for
usage or Git errors. Logs and a JSON report go to test-results/probe/<sha>/<unit>/; baselines are
shared by the probes of one commit (test-results/probe/<sha>/baseline.json); the scratch worktree
is always removed.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify  # noqa: E402  (selection and runners)

sys.path.insert(0, str(verify.ROOT / "tools" / "ownership"))
import cards  # noqa: E402  (references between modules)

XCODE_RUNNERS = {"ios", "ios-lanes", "mac"}


def git(cwd: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if check and done.returncode:
        raise verify.VerifyError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def unit_files(unit: str, modules: dict, tracked: list[str]) -> tuple[str, list[str]]:
    if unit in modules:
        return unit, sorted(modules[unit]["owned"])
    clean = unit.rstrip("/")
    files = [path for path in tracked if path == clean or path.startswith(clean + "/")]
    if not files:
        raise verify.VerifyError(f"{unit!r} is neither a module id nor a tracked path")
    return clean, files


def names_of(unit: str, files: list[str]) -> set[str]:
    """Words a failure message would use to point at the unit."""
    found = {unit, unit.rsplit("/", 1)[-1]}
    for path in files:
        name = path.rsplit("/", 1)[-1]
        found |= {path, name, name.rsplit(".", 1)[0]}
    return {name for name in found if len(name) > 3}


def guardians(unit: str, files: list[str], modules: dict, tracked: list[str]) -> tuple[list[str], dict[str, str]]:
    """Tests verify would select for the change, plus every test that names the unit, or names a file of its
    own module that names the unit (one hop: a consumer's source and the tests that exercise it)."""
    selection = verify.select("changed", None, "HEAD", modules, tracked, paths=files)
    chosen = {path: "selected by verify" for path in selection["tests"] + selection["deferredTests"]}
    owner = {path: key for key, module in modules.items() for path in module["owned"]}
    paths, read = verify.ownership.inventory(None)
    refs = cards.references(paths, read, owner)
    gone = set(files)
    naming = {source for source, targets in refs.items() if source not in gone
              and any(cards.covers(target, path) for target in targets for path in gone)}
    for source in sorted(naming):
        if verify.is_test(source):
            chosen.setdefault(source, f"names the unit")
            continue
        for test, targets in refs.items():
            if verify.is_test(test) and test not in gone and source in targets and owner.get(test) == owner.get(source):
                chosen.setdefault(test, f"names {source}, which names the unit")
    return sorted(test for test in chosen if test not in gone), chosen


def command(scratch: Path, test: str, runner: str) -> tuple[list[str], Path]:
    node = [str(scratch / "scripts/tron-node"), "exec"]
    if runner in ("gateway", "gateway-nested"):
        config = ["--config", "vitest.nested.config.ts"] if runner == "gateway-nested" else []
        return ["python3", str(scratch / "tools/verify/gateway.py"), *config, test[len(verify.GATEWAY) + 1:]], scratch / verify.GATEWAY
    if runner == "node-gateway":
        return node + ["node", "--test", test[len(verify.GATEWAY) + 1:]], scratch / verify.GATEWAY
    if runner == "node":
        return node + ["node", "--test", test], scratch
    if runner == "python":
        return ["python3", test], scratch
    return ["bash", test], scratch


def run_tests(scratch: Path, tests: list[str], logs: Path, jobs: int, timeout: float) -> dict[str, dict]:
    nested, mac_terminal = verify.nested_files()
    logs.mkdir(parents=True, exist_ok=True)

    def one(test: str) -> tuple[str, dict]:
        runner = verify.runner_of(test, nested, mac_terminal)
        if runner in XCODE_RUNNERS:
            return test, {"outcome": "not-run", "why": f"{runner} needs Xcode; run it through scripts/tron verify"}
        argv, cwd = command(scratch, test, runner)
        private = Path(tempfile.mkdtemp(prefix="probe-test-"))
        env = {**os.environ, "TMPDIR": str(private) + "/"}
        started = time.time()
        try:
            done = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
                                  start_new_session=True)
            output, code = done.stdout + done.stderr, done.returncode
        except subprocess.TimeoutExpired as expired:
            output = f"{expired.stdout or ''}{expired.stderr or ''}\nprobe: timed out after {timeout}s"
            code = 124
        finally:
            shutil.rmtree(private, ignore_errors=True)
        log = logs / (test.replace("/", "__") + ".log")
        log.write_text(output if isinstance(output, str) else output.decode(errors="replace"))
        return test, {"outcome": "pass" if code == 0 else "fail", "exit": code, "seconds": round(time.time() - started, 1),
                      "log": str(log.relative_to(verify.ROOT))}

    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        return dict(pool.map(one, tests))


def static_check(scratch: Path) -> list[str]:
    done = subprocess.run(["python3", str(scratch / "tools/ownership/ownership.py")], cwd=scratch, capture_output=True, text=True)
    return [line for line in (done.stdout + done.stderr).splitlines() if line and not line.startswith("ownership: ")]


def drop_owns(scratch: Path, manifests: list[str], files: list[str], renamed: dict[str, str],
              removed_modules: set[str]) -> None:
    """Keep each manifest true to the tree: an exact owns entry follows its file, a deleted file loses it."""
    for manifest in manifests:
        path = scratch / manifest
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        folder = str(Path(manifest).parent)
        prefix = "" if folder == "." else folder + "/"
        owns = []
        for entry in data.get("owns", []):
            full = prefix + entry
            if full in renamed and renamed[full].startswith(prefix):
                owns.append(renamed[full][len(prefix):])
            elif full not in files:
                owns.append(entry)
        if owns != data.get("owns"):
            data["owns"] = owns
            path.write_text(json.dumps(data, indent=2) + "\n")
    # A clean removal also drops the unit from the layout lists; a frozen path stays listed, so removing one is reported.
    root = scratch / "root.module.json"
    if root.exists():
        data = json.loads(root.read_text())
        layout = data.get("layout")
        if isinstance(layout, dict):
            gone_modules = set(removed_modules)
            if isinstance(layout.get("scriptsTop"), list):
                moved_top = [new for old, new in renamed.items() if old in layout["scriptsTop"] and new.count("/") == 1]
                layout["scriptsTop"] = sorted({entry for entry in layout["scriptsTop"] if entry not in files and entry not in renamed}
                                              | set(moved_top))
            if isinstance(layout.get("uncarded"), list):
                layout["uncarded"] = [entry for entry in layout["uncarded"] if entry not in gone_modules]
            root.write_text(json.dumps(data, indent=2) + "\n")


def classify(failing: dict[str, str], names: set[str]) -> tuple[str, list[str]]:
    if not failing:
        return "silent", []
    vague = [test for test, output in failing.items() if not any(name in output for name in names)]
    if vague:
        return "cascade", vague
    return "precise", []


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron probe")
    parser.add_argument("unit", help="tracked file, directory or module id")
    parser.add_argument("--move", metavar="NEW_PATH", help="move the unit (one file) instead of deleting it; callers are not updated")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=900, help="seconds one test file may take")
    args = parser.parse_args(argv)
    try:
        result, _ = verify.ownership.check()
        modules, tracked = result["modules"], result["tracked"]
        unit, files = unit_files(args.unit, modules, tracked)
        if args.move and len(files) != 1:
            parser.error("--move takes one tracked file")
        sha = git(verify.ROOT, "rev-parse", "HEAD").strip()
        if git(verify.ROOT, "status", "--porcelain", "--untracked-files=no").strip():
            print("probe: uncommitted changes are not part of the probe; it checks out HEAD", file=sys.stderr)
        tests, why = guardians(unit, files, modules, tracked)
    except (verify.VerifyError, verify.ownership.GitError) as error:
        print(f"probe: {error}", file=sys.stderr)
        return 2
    slug = re.sub(r"[^A-Za-z0-9._-]+", "__", unit) + (f"--move--{re.sub(r'[^A-Za-z0-9._-]+', '__', args.move)}" if args.move else "")
    out = verify.ROOT / "test-results" / "probe" / sha / slug
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    action = f"move to {args.move}" if args.move else "delete"
    print(f"probe {unit} ({len(files)} file(s), {action}) at {sha[:12]}: {len(tests)} guardian test file(s)", flush=True)
    scratch = Path(tempfile.mkdtemp(prefix="tron-probe-")) / "tree"
    git(verify.ROOT, "worktree", "add", "--detach", "-q", str(scratch), sha)
    try:
        # Installed Gateway dependencies are reused read-only: this checkout's, else the primary checkout's.
        common = Path(git(verify.ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
        modules_dir = next((candidate for candidate in (verify.ROOT / verify.GATEWAY / "node_modules",
                                                         common.parent / verify.GATEWAY / "node_modules")
                            if candidate.is_dir()), None)
        if modules_dir:
            (scratch / verify.GATEWAY / "node_modules").symlink_to(modules_dir)
        # A guardian's baseline depends only on the commit, so probes of one commit share it.
        cache = out.parent / "baseline.json"
        known = json.loads(cache.read_text()) if cache.exists() else {}
        fresh = run_tests(scratch, [test for test in tests if test not in known], out.parent / "baseline", args.jobs, args.timeout)
        if fresh:
            known = {**(json.loads(cache.read_text()) if cache.exists() else {}), **fresh}
            cache.write_text(json.dumps(known, indent=2, sort_keys=True) + "\n")
        baseline = {test: known[test] for test in tests}
        red = sorted(test for test, outcome in baseline.items() if outcome["outcome"] == "fail")
        if red:
            print(f"probe: {len(red)} guardian(s) already fail at HEAD; fix them first: {', '.join(red)}", file=sys.stderr)
            (out / "report.json").write_text(json.dumps({"unit": unit, "sha": sha, "baselineRed": red}, indent=2) + "\n")
            return 1
        before = static_check(scratch)
        manifests = sorted({modules[key]["manifest"] for key in modules for path in files if path in modules[key]["owned"]})
        renamed = {}
        if args.move:
            (scratch / args.move).parent.mkdir(parents=True, exist_ok=True)
            git(scratch, "mv", files[0], args.move)
            renamed = {files[0]: args.move}
        else:
            git(scratch, "rm", "-r", "-q", "--", *files)
        removed = {unit} if unit in modules and not args.move else set()
        drop_owns(scratch, manifests, [] if args.move else files, renamed, removed)
        git(scratch, "add", "-A")
        git(scratch, "-c", "user.name=probe", "-c", "user.email=probe@example.invalid", "commit", "-q", "--no-verify",
            "-m", f"probe: {action} {unit}")
        static = [line for line in static_check(scratch) if line not in before]
        after = run_tests(scratch, tests, out / "after", args.jobs, args.timeout)
    finally:
        git(verify.ROOT, "worktree", "remove", "--force", str(scratch), check=False)
        shutil.rmtree(scratch.parent, ignore_errors=True)
        git(verify.ROOT, "worktree", "prune", check=False)
    names = names_of(unit, files)
    failing = {test: (verify.ROOT / outcome["log"]).read_text() for test, outcome in after.items()
               if outcome["outcome"] == "fail" and baseline[test]["outcome"] == "pass"}
    verdict, vague = classify(failing, names)
    report = {"schema": "tron.probe.v1", "unit": unit, "action": action, "sha": sha, "files": files, "verdict": verdict,
              "failing": sorted(failing), "vague": vague, "static": static,
              "notRun": sorted(test for test, outcome in after.items() if outcome["outcome"] == "not-run"),
              "guardians": {test: {"why": why[test], "baseline": baseline[test], "after": after[test]} for test in tests}}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"verdict: {verdict.upper()}  ({len(failing)} failing test file(s); {len(static)} static finding(s))")
    for test in sorted(failing):
        line = next((line.strip() for line in failing[test].splitlines() if any(name in line for name in names)
                     and re.search(r"error|fail|no such|not found|missing|cannot|assert", line, re.I)), "")
        print(f"  red  {test}{'  (does not name the unit)' if test in vague else ''}\n       {line[:200]}")
    for line in static:
        print(f"  static  {line[:240]}")
    if report["notRun"]:
        print(f"  not run (Xcode): {', '.join(report['notRun'])}")
    print(f"report {out.relative_to(verify.ROOT)}/report.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
