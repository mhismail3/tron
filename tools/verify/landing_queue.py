#!/usr/bin/env python3
"""Shadow landing queue: on the Mac mini, run verify --full on every landing on main, serially, into an append-only ledger."""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

LABEL = "com.tron.shadow-queue"
QUEUE = Path.home() / "tron-ci/queue"
CLONE = QUEUE / "tron"
RESULTS = CLONE / "test-results/queue"
LEDGER = RESULTS / "ledger.jsonl"
JOB_LOCK = Path.home() / "tron-ci/jobs/gateway.lock"
TEST_LEDGER = Path.home() / ".tron-maintenance/test-ledger/results.sqlite3"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
INTERVAL = 300
SKIP = "ios,mac,python-here"
TIER1 = {"tests: gateway", "tests: python", "tests: node", "tests: relay"}
KEEP = ["/test-results/queue", "/packages/gateway/node_modules", "/packages/push-relay/node_modules"]
INSTALLS = {"packages/gateway": ("package.json", "package-lock.json", "third_party"), "packages/push-relay": ("package.json", "package-lock.json")}


def git(*args: str, cwd: Path = CLONE) -> str:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout.strip()


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def environment() -> dict:
    env = {"HOME": str(Path.home()), "LANG": os.environ.get("LANG", "en_US.UTF-8"), "PYTHONDONTWRITEBYTECODE": "1",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "TRON_CI_TOOLS_DIR": str(Path.home() / "tron-ci/.ci-tools"),
           **{key: os.environ[key] for key in ("USER", "LOGNAME", "SHELL") if key in os.environ}}
    node = subprocess.run([str(CLONE / "scripts/tron-node")], env=env, capture_output=True, text=True)
    if node.returncode:
        raise RuntimeError(f"no pinned Node: {node.stderr.strip()}")
    return {**env, "PATH": f"{Path(node.stdout.strip()).parent}:{env['PATH']}"}


def step(command: list[str], env: dict, log, cwd: Path = CLONE) -> int:
    with subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                          start_new_session=True) as child:
        try:
            return child.wait()
        except BaseException:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait()
            raise


def prepare(commit: str, log) -> dict:
    """Check out `commit` cleanly, install its changed dependencies and return its environment; RuntimeError if it cannot."""
    git("checkout", "--quiet", "--detach", "--force", commit)
    clean = ["clean", "-ffdxq", *[word for path in KEEP for word in ("-e", path)]]
    try:
        git(*clean)
    except RuntimeError:
        subprocess.run(["chmod", "-R", "u+w", str(CLONE)], check=True)
        git(*clean)
    env = environment()
    for package, inputs in INSTALLS.items():
        stamp = CLONE / package / "node_modules/.tron-queue-install"
        key = git("rev-parse", *(f"HEAD:{package}/{name}" for name in inputs)) + env["PATH"]
        if stamp.is_file() and stamp.read_text() == key:
            continue
        if step([str(CLONE / "scripts/tron-node"), "exec", "npm", "--prefix", package, "ci", "--include=dev"], env, log):
            raise RuntimeError(f"npm ci in {package} failed")
        stamp.write_text(key)
    return env


def tiers(report: dict) -> dict:
    result = {}
    for item in report.get("steps", []):
        name = item["name"]
        tier = "0" if not name.startswith("tests:") else "1" if name in TIER1 else "2"
        if item["status"] == "skipped":
            continue
        entry = result.setdefault(tier, {"verdict": "passed", "seconds": 0.0, "failedSteps": []})
        entry["seconds"] = round(entry["seconds"] + (item.get("seconds") or 0), 1)
        if item["status"] == "failed":
            entry["verdict"] = "failed"
            entry["failedSteps"].append(name)
        elif item["status"] in ("no result", "interrupted", "running") and entry["verdict"] != "failed":
            entry["verdict"] = "no result"
    return result


def failed_tests(commit: str, since: str) -> list[str]:
    if not TEST_LEDGER.is_file():
        return []
    with closing(sqlite3.connect(TEST_LEDGER.as_uri() + "?mode=ro", uri=True)) as connection:
        rows = connection.execute("SELECT DISTINCT lane, test_id FROM results WHERE commit_sha = ? AND seen_at >= ? AND outcome = 'failed' "
                                  "ORDER BY lane, test_id", (commit, since)).fetchall()
    return [f"{lane}: {test}" for lane, test in rows]


def shadow(landing: str) -> dict:
    """Run the full suite at the landing `landing` and return its ledger entry."""
    landing, *parents = git("rev-list", "--parents", "-n", "1", landing).split()
    directory = RESULTS / landing
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    started, clock = now(), time.monotonic()
    entry = {"kind": "run", "landing": landing, "parents": parents, "subject": git("log", "-1", "--format=%s", landing),
             "landedAt": git("log", "-1", "--format=%cI", landing), "host": os.uname().nodename,
             "startedAt": started}
    with open(directory / "verify.log", "w") as log:
        try:
            env = prepare(landing, log)
            code, reason = step(["/usr/bin/python3", "tools/verify/verify.py", "--full", "--base", parents[0],
                                 "--gateway-host", "local", "--skip", SKIP], env, log), None
        except RuntimeError as error:
            code, reason = None, str(error)
    report_path = CLONE / "test-results/verify" / f"{landing}.json"
    report = json.loads(report_path.read_text()) if code is not None and report_path.is_file() else {}
    for source in (report_path, report_path.with_suffix("")):
        if source.exists():
            source.rename(directory / ("verify.json" if source == report_path else "logs"))
    verdict = report.get("verdict")
    entry.update(seconds=round(time.monotonic() - clock), endedAt=now(),
                 verdict="passed" if verdict == "passed" else "failed" if verdict == "failed" else "no result",
                 reason=reason or report.get("message") or f"verify exited {code} without a report",
                 tiers=tiers(report), failedTests=failed_tests(landing, started))
    return entry


def entries(lines: list[str]) -> list[dict]:
    return [json.loads(line) for line in lines if line.strip()]


def run(since: str | None) -> int:
    JOB_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(JOB_LOCK, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"{now()} queue: the mini job lock is held; next interval", flush=True)
            return 0
        lock.seek(0)
        lock.truncate()
        lock.write(json.dumps({"host": os.uname().nodename, "purpose": "shadow queue", "pid": os.getpid()}))
        lock.flush()
        git("fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        RESULTS.mkdir(parents=True, exist_ok=True)
        done = [entry["landing"] for entry in entries(LEDGER.read_text().splitlines() if LEDGER.is_file() else []) if entry["kind"] == "run"]
        start = since or (done[-1] if done else None)
        pending = git("rev-list", "--first-parent", "--reverse", f"{start}..origin/main").split() if start else [git("rev-parse", "origin/main")]
        landing = next((commit for commit in pending if commit not in done), None)
        if landing is None:
            return 0
        print(f"{now()} queue: {landing[:12]} started, {len(pending) - 1} more waiting", flush=True)
        entry = shadow(landing)
        with open(LEDGER, "a") as ledger:
            ledger.write(json.dumps(entry, sort_keys=True) + "\n")
        print(f"{now()} queue: {landing[:12]} {entry['verdict']} in {entry['seconds']}s", flush=True)
    return 0


def install() -> int:
    if not (CLONE / ".git").is_dir():
        print(f"queue: clone the repository first: git clone https://github.com/<owner>/tron.git {CLONE}", file=sys.stderr)
        return 2
    QUEUE.mkdir(parents=True, exist_ok=True)
    runner = QUEUE / "landing_queue.py"
    runner.write_bytes(Path(__file__).read_bytes())
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    PLIST.write_bytes(plistlib.dumps({"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", str(runner), "run"],
                                      "StartInterval": INTERVAL, "RunAtLoad": True, "ProcessType": "Background",
                                      "StandardOutPath": str(QUEUE / "queue.log"), "StandardErrorPath": str(QUEUE / "queue.log")}))
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
    return subprocess.run(["launchctl", "bootstrap", domain, str(PLIST)]).returncode


def uninstall() -> int:
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
    PLIST.unlink(missing_ok=True)
    print(f"queue: stopped and removed {PLIST}; the ledger and clone stay in {QUEUE}", flush=True)
    return 0


def claims(runs: list[dict], known: set[str]) -> list[dict]:
    """Each landing's own `verify --changed` report found in this Mac's checkouts, for landings with no claim yet."""
    reports: dict[str, list[dict]] = {}
    root = Path(__file__).resolve().parents[2]
    trees = [Path(line[len("worktree "):]) for line in git("worktree", "list", "--porcelain", cwd=root).splitlines() if line.startswith("worktree ")]
    for tree in trees:
        for path in [*tree.glob("test-results/verify/*.json"), *tree.glob("test-results/mini/*/verify.json")]:
            try:
                data = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if data.get("selection", {}).get("mode") == "changed" and data.get("verdict") not in ("running", None):
                reports.setdefault(data.get("commit", ""), []).append({**data, "path": str(path)})
    found = []
    for entry in runs:
        if entry["landing"] in known or len(entry["parents"]) < 2:
            continue
        try:
            commits = git("rev-list", f"{entry['parents'][0]}..{entry['parents'][1]}", cwd=root).split()
        except RuntimeError:
            continue
        for commit in commits:
            if commit in reports:
                data = max(reports[commit], key=lambda report: report.get("endedAt") or "")
                found.append({"kind": "claim", "landing": entry["landing"], "commit": commit, "verdict": data["verdict"],
                              "message": data.get("message", "")[:400], "report": data["path"],
                              "failedSteps": [item["name"] for item in data.get("steps", []) if item["status"] == "failed"],
                              "failedTests": [test for item in data.get("steps", []) for test in item.get("failedTests", [])]})
                break
    return found


def quantile(values: list[float], share: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(share * len(ordered)) - 1)] if ordered else 0


def show(mini: bool) -> int:
    if mini:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import mini as host
        ssh = host.ssh_command()
        lines = subprocess.run([*ssh, f"cat {LEDGER.relative_to(Path.home())}"], check=True, capture_output=True, text=True).stdout.splitlines()
        rows = entries(lines)
        found = claims([row for row in rows if row["kind"] == "run"], {row["landing"] for row in rows if row["kind"] == "claim"})
        if found:
            payload = "".join(json.dumps(row, sort_keys=True) + "\n" for row in found)
            subprocess.run([*ssh, f"cat >> {LEDGER.relative_to(Path.home())}"], input=payload, check=True, text=True)
            rows += found
    else:
        rows = entries(LEDGER.read_text().splitlines() if LEDGER.is_file() else [])
    claimed = {row["landing"]: row for row in rows if row["kind"] == "claim"}
    runs = sorted((row for row in rows if row["kind"] == "run"), key=lambda row: row["landedAt"])
    print(f"{'LANDED':16}  {'LANDING':9}  {'VERDICT':9}  {'SECONDS':>7}  {'TIER 0':13}  {'TIER 1':13}  {'TIER 2':13}  CLAIM")
    for row in runs:
        cells = [f"{row['tiers'][tier]['verdict']} {round(row['tiers'][tier]['seconds'])}" if tier in row["tiers"] else "-" for tier in "012"]
        claim = claimed.get(row["landing"])
        print(f"{row['landedAt'][:16].replace('T', ' '):16}  {row['landing'][:9]}  {row['verdict']:9}  {row['seconds']:>7}  "
              f"{cells[0]:13}  {cells[1]:13}  {cells[2]:13}  {claim['verdict'] + ' at ' + claim['commit'][:9] if claim else 'none found'}")
        if row["verdict"] != "passed":
            for name in [step for tier in row["tiers"].values() for step in tier["failedSteps"]] or [row["reason"]]:
                print(f"    red: {name}")
            for test in row["failedTests"]:
                print(f"    failed: {test}")
        if claim and claim["verdict"] != "passed":
            for test in claim["failedTests"] or claim["failedSteps"]:
                print(f"    claim red: {test}")
    days: dict[str, list[int]] = {}
    for row in runs:
        days.setdefault(row["landedAt"][:10], []).append(row["verdict"] == "failed")
    print("\nreds per day: " + ", ".join(f"{day} {sum(reds)}/{len(reds)}" for day, reds in sorted(days.items())))
    measured = [row for row in runs if row["verdict"] != "no result"]
    for label, values in [("total", [row["seconds"] for row in measured]),
                          *[(f"tier {tier}", [row["tiers"][tier]["seconds"] for row in measured if tier in row["tiers"]]) for tier in "012"]]:
        print(f"seconds {label}: p50 {round(quantile(values, 0.5))}, p95 {round(quantile(values, 0.95))} over {len(values)} run(s)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron queue")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("run", help="run the next landing after the ledger's last (or --since) on this mini").add_argument("--since")
    commands.add_parser("install", help=f"copy this runner to {QUEUE} and load the {LABEL} LaunchAgent")
    commands.add_parser("uninstall", help="unload and remove the LaunchAgent; keep the ledger")
    commands.add_parser("ledger", help="print the ledger").add_argument("--mini", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "run":
        return run(args.since)
    if args.command == "ledger":
        return show(args.mini)
    return install() if args.command == "install" else uninstall()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main(sys.argv[1:]))
