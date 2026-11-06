#!/usr/bin/env python3
"""scripts/tron probe: remove or move one unit in a scratch worktree and see which checks go red.

A unit is a tracked file, a directory or a module id. The probe runs the unit's guardians on HEAD
(baseline), applies the change in a private worktree (delete, or `--move` without updating any
caller), commits it and runs the same checks again; every test runs in its own private checkout. Guardians are
the tests `scripts/tron verify` selects for the unit plus the tests of every module whose files
name it (tools/ownership/cards.py), and the static `scripts/tron ownership` check. The verdict:

- precise: tests that passed now fail, and every failure's output names the unit;
- cascade: some failure never names the unit, so its reader cannot tell what broke;
- silent: no test fails. The unit is either dead (delete it) or unguarded (add a test that
  fails before and passes after). The static check is reported separately.

It measures and never gates; exit 0 after any verdict, 1 when every guardian is already red at HEAD
(a guardian red before the change is left out and reported), 2 for usage or Git errors. Logs and a JSON report go to test-results/probe/<sha>/<unit>/; baselines are
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
import signal
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify  # noqa: E402  (selection and runners)

sys.path.insert(0, str(verify.ROOT / "tools" / "ownership"))
import cards  # noqa: E402  (references between modules)



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


def names_of(unit: str, files: list[str]) -> list[re.Pattern]:
    """How a failure message points at the unit: a repo-relative path, or a distinctive file name.

    A short or common name ("tron", "data") also occurs in scratch paths and unrelated text, so it
    alone never counts as naming the unit."""
    names = {unit, *files}
    for path in files:
        name = path.rsplit("/", 1)[-1]
        stem = name.rsplit(".", 1)[0]
        names |= {candidate for candidate in (name, stem) if len(candidate) >= 8 and re.search(r"[-_.]", candidate)}
    return [re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_-])") for name in sorted(names)]


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


RUNNING: set = set()  # test process groups this probe started; stopped on interrupt or SIGTERM
STOPPING = threading.Event()
# `git worktree add` and `remove` edit the repository's shared worktree list; guardians run in
# parallel threads, so these edits take turns rather than race for its lock.
WORKTREES = threading.Lock()


def writable(path: Path) -> None:
    """Restore owner-write on a tree a guardian may have sealed read-only (bundle-gateway.sh seals payloads)."""
    for folder, directories, _ in os.walk(path):
        for name in [folder, *(os.path.join(folder, d) for d in directories)]:
            try:
                os.chmod(name, os.stat(name, follow_symlinks=False).st_mode | 0o700, follow_symlinks=False)
            except (OSError, NotImplementedError):
                pass


def remove_tree(path: Path) -> None:
    """Delete a scratch tree, sealed or not; say so if it stays."""
    if not path.exists():
        return
    writable(path)
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        print(f"probe: could not remove {path}; remove it by hand", file=sys.stderr)


def stop_running() -> None:
    STOPPING.set()
    for process in list(RUNNING):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:  # gone already; macOS reports a reaped group as EPERM
            pass


def checkout(commit: str, dependencies: Path | None) -> Path:
    """A private worktree of `commit`, with a copy-on-write clone of the installed Gateway dependencies: a
    guardian may reinstall them (bundle-gateway.sh runs `npm ci`) or write into its checkout, and neither
    may reach another checkout or a guardian running beside it."""
    tree = Path(tempfile.mkdtemp(prefix="tron-probe-")) / "tree"
    try:
        with WORKTREES:
            git(verify.ROOT, "worktree", "add", "--detach", "-q", str(tree), commit)
        if dependencies:
            (tree / verify.GATEWAY).mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-c", "-R", str(dependencies), str(tree / verify.GATEWAY / "node_modules")], check=True)
    except BaseException:
        discard(tree)
        raise
    return tree


def discard(tree: Path) -> None:
    """Remove one of this probe's worktrees; other checkouts' worktree entries are not touched."""
    if tree.exists():
        writable(tree)
    with WORKTREES:
        git(verify.ROOT, "worktree", "remove", "--force", str(tree), check=False)
        listed = git(verify.ROOT, "worktree", "list", "--porcelain")
    if str(tree.resolve()) in listed:
        print(f"probe: could not unregister worktree {tree}; run `git worktree remove --force {tree}`", file=sys.stderr)
    remove_tree(tree.parent)


def run_tests(commit: str, dependencies: Path | None, tests: list[str], logs: Path, jobs: int,
              timeout: float) -> dict[str, dict]:
    """Each test in its own checkout of `commit`, as `scripts/tron verify` runs it in a clean worktree."""
    nested, mac_terminal = verify.nested_files()
    logs.mkdir(parents=True, exist_ok=True)

    def one(test: str) -> tuple[str, dict]:
        try:
            runner = verify.runner_of(test, nested, mac_terminal)
        except verify.VerifyError as error:
            return test, {"outcome": "not-run", "why": str(error)}
        if runner in verify.NOT_DRIVEN or runner == "ios":
            return test, {"outcome": "not-run", "why": f"the {runner} runner needs its own lane; run it through scripts/tron verify"}
        if STOPPING.is_set():
            return test, {"outcome": "not-run", "why": "the probe was stopped"}
        started, scratch, private, process = time.time(), None, None, None
        try:
            scratch = checkout(commit, dependencies)
            if STOPPING.is_set():
                return test, {"outcome": "not-run", "why": "the probe was stopped"}
            argv, cwd = command(scratch, test, runner)
            private = Path(tempfile.mkdtemp(prefix="probe-test-"))
            try:
                process = subprocess.Popen(argv, cwd=cwd, env={**os.environ, "TMPDIR": str(private) + "/"},
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                           start_new_session=True)
            except OSError as error:  # the change removed the runner itself (scripts/tron-node, a deleted cwd)
                output, code = f"probe: cannot start {' '.join(argv)} in {cwd}: {error}", 127
            else:
                RUNNING.add(process)
                try:
                    output, _ = process.communicate(timeout=timeout)
                    code = process.returncode
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    output, _ = process.communicate()
                    output, code = f"{output}\nprobe: timed out after {timeout}s", 124
        finally:
            if process is not None:
                RUNNING.discard(process)
                try:  # a test's own descendants belong to its group, also after a clean exit
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:  # gone already; macOS reports a reaped group as EPERM
                    pass
            if private is not None:
                remove_tree(private)
            if scratch is not None:
                discard(scratch)
        log = logs / (test.replace("/", "__") + ".log")
        log.write_text(output)
        return test, {"outcome": "pass" if code == 0 else "fail", "exit": code, "seconds": round(time.time() - started, 1),
                      "log": str(log.relative_to(verify.ROOT))}

    pool = concurrent.futures.ThreadPoolExecutor(max(1, jobs))
    try:
        return dict(pool.map(one, tests))
    except BaseException:
        stop_running()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)


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


def classify(failing: dict[str, str], names: list[re.Pattern]) -> tuple[str, list[str]]:
    if not failing:
        return "silent", []
    vague = [test for test, output in failing.items() if not any(name.search(output) for name in names)]
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
    # SIGTERM unwinds like an interrupt, so the scratch worktree and every test group are removed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
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
    # Installed Gateway dependencies: this checkout's, else the primary checkout's; each test gets a clone.
    common = Path(git(verify.ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    dependencies = next((candidate.resolve() for candidate in (verify.ROOT / verify.GATEWAY / "node_modules",
                                                               common.parent / verify.GATEWAY / "node_modules")
                         if (candidate / ".bin").is_dir()), None)
    scratch = None
    try:
        scratch = checkout(sha, None)
        # A guardian's baseline depends only on the commit, so probes of one commit share it.
        cache = out.parent / "baseline.json"
        known = json.loads(cache.read_text()) if cache.exists() else {}
        fresh = run_tests(sha, dependencies, [test for test in tests if test not in known], out.parent / "baseline",
                          args.jobs, args.timeout)
        if fresh:
            known = {**(json.loads(cache.read_text()) if cache.exists() else {}), **fresh}
            cache.write_text(json.dumps(known, indent=2, sort_keys=True) + "\n")
        baseline = {test: known[test] for test in tests}
        red = sorted(test for test, outcome in baseline.items() if outcome["outcome"] == "fail")
        if red:
            # A guardian red before the change says nothing about the unit; the rest still can.
            print(f"probe: {len(red)} guardian(s) already fail at HEAD and are left out; fix them: {', '.join(red)}",
                  file=sys.stderr)
            tests = [test for test in tests if test not in red]
            if not tests:
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
        changed = git(scratch, "rev-parse", "HEAD").strip()
        static = [line for line in static_check(scratch) if line not in before]
        after = run_tests(changed, dependencies, tests, out / "after", args.jobs, args.timeout)
    except (OSError, subprocess.CalledProcessError, verify.VerifyError) as error:
        print(f"probe: could not prepare a checkout: {error}", file=sys.stderr)
        return 2
    finally:
        if scratch is not None:
            discard(scratch)
    names = names_of(unit, files)
    failing = {test: (verify.ROOT / outcome["log"]).read_text() for test, outcome in after.items()
               if outcome["outcome"] == "fail" and baseline[test]["outcome"] == "pass"}
    verdict, vague = classify(failing, names)
    report = {"schema": "tron.probe.v1", "unit": unit, "action": action, "sha": sha, "files": files, "verdict": verdict,
              "failing": sorted(failing), "vague": vague, "static": static, "baselineRed": red,
              "notRun": sorted(test for test, outcome in after.items() if outcome["outcome"] == "not-run"),
              "guardians": {test: {"why": why[test], "baseline": baseline[test], "after": after[test]} for test in tests}}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"verdict: {verdict.upper()}  ({len(failing)} failing test file(s); {len(static)} static finding(s))")
    for test in sorted(failing):
        lines = failing[test].splitlines()
        problem = re.compile(r"error|fail|no such|not found|missing|cannot|assert", re.I)
        # The line that names the unit; for a vague failure, its first error so the reader sees what it said.
        line = next((line.strip() for line in lines if any(name.search(line) for name in names) and problem.search(line)),
                    next((line.strip() for line in lines if problem.search(line)),
                         next((line.strip() for line in lines if line.strip()), "(no output)")))
        print(f"  red  {test}{'  (does not name the unit)' if test in vague else ''}\n       {line[:200]}")
    for line in static:
        print(f"  static  {line[:240]}")
    if report["notRun"]:
        print(f"  not run (own lane): {', '.join(report['notRun'])}")
    print(f"report {out.relative_to(verify.ROOT)}/report.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
