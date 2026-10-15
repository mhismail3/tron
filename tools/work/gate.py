#!/usr/bin/env python3
"""`scripts/tron gate`: the one runner for every verification step (README.md#gate, #1022).

`gate-catalog.json` is the source of truth: each step's trigger, command, cache
inputs, budget, hard timeout, resource class and the gate it unlocks. The
classifier turns the change (the worktree against its merge base with the
configured base branch) into the ordered plan of the steps it needs; plan order
is catalog order, so the same change always gets the same plan.

A step expands into shards. Each shard has its own content-addressed cache key
(its expanded command plus the git tree of its inputs in the worktree, dirty or
not), so a retry reruns only shards that failed or whose inputs changed. A
passing shard is recorded under the common Git directory; `cacheScope:
worktree` keys also bind the worktree because their products live there.

Running prints one line per shard as it starts and a heartbeat with elapsed
time, budget and live tree RSS while it runs, stops at the first failure with
the log tail, and kills a shard that exceeds its hard timeout, naming it. Heavy
shards wait for the host-wide heavy queue (heavy.py) with their expected RSS;
light shards never wait. Every finished shard appends its wall time, peak tree
RSS and CPU to `<git common dir>/work/gate/metrics.jsonl`, which `report`
summarizes.
"""
from __future__ import annotations

import argparse
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

import heavy  # noqa: E402

# TRON_GATE_CATALOG exists for scripts/test-gate.py, which exercises the runner on a fixture catalog.
CATALOG = Path(os.environ.get("TRON_GATE_CATALOG") or Path(__file__).resolve().parent / "gate-catalog.json")
HEARTBEAT_SECONDS = float(os.environ.get("TRON_GATE_HEARTBEAT_SECONDS") or 15)
SAMPLE_SECONDS = 0.5
EXCERPT_LINES = 40
_TEST_FILE = re.compile(r"\.(test|spec)\.(ts|tsx|mts|mjs|js)$")
_TS_FILE = re.compile(r"\.(ts|tsx|mts|mjs|js|json)$")
_SCRIPT_SUFFIXES = {".py": "python", ".mjs": "node", ".js": "node", ".sh": "shell"}


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
            if re.match(r"^scripts/test-[\w-]+\.py$", path):
                suites.append(path)
            elif path.startswith("tools/work/"):
                stem = Path(path).stem
                target = {"gate": "test-gate", "heavy": "test-tron-heavy", "verify": "test-gate", "land": "test-work-land",
                          "cli": "test-gate"}.get(stem, f"test-work-{stem}")
                if (root / f"scripts/{target}.py").is_file():
                    suites.append(f"scripts/{target}.py")
            elif re.match(r"^scripts/tron_mac_(replace|reinstall)", path):
                pass  # mac.replace-e2e owns these
            elif path.startswith("scripts/") and Path(path).suffix in (".py", ""):
                stem = Path(path).name.replace("_", "-").removesuffix(".py")
                for candidate in (f"scripts/test-{stem}.py",):
                    if (root / candidate).is_file():
                        suites.append(candidate)
        return [f"python3 -B {s}" for s in dict.fromkeys(suites)]
    if name == "ios-journeys":
        classes = []
        for path in change.existing():
            if path.startswith("packages/ios-app/UITests/") and path.endswith("UITests.swift") and "/RealGateway/" not in path:
                classes.append(f"--only-testing TronMobileUITests/{Path(path).stem}")
        return list(dict.fromkeys(classes)) or [""]
    if name == "named-journeys":
        return list(change.tests)
    raise GateError(f"unknown selector {name}")


def plan(catalog: dict, change: Change) -> List[Shard]:
    """The ordered shards the change needs (catalog order; shards in index order)."""
    exclude = catalog.get("codeExclude", [])
    code = [p for p in change.paths if not _matches(p, exclude)]
    selected: List[Shard] = []
    for step in catalog["steps"]:
        trigger = step["trigger"]
        candidates = code if trigger.get("code") else change.paths
        needed = trigger.get("always") or ("paths" in trigger and any(_matches(p, trigger["paths"]) for p in candidates))
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
        return selection.rsplit("/", 1)[-1] if selection else "smoke"
    if select == "tooling-tests":
        return Path(selection.split()[-1]).stem
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


def cache_key(root: Path, change: Change, shard: Shard) -> str:
    step = shard.step
    listing = _git(root, "ls-tree", "-r", "--full-tree", change.tree, "--", *step["inputs"])
    scope = {
        "gate": 1,
        "step": step["id"],
        "command": shard.command,
        "inputs": hashlib.sha256(listing.encode()).hexdigest(),
        "extra": [_key_extra(name) for name in step.get("keyExtra", [])],
        "worktree": str(root) if step.get("cacheScope") == "worktree" else None,
    }
    # Commands that compare against the merge base depend on it beyond their inputs.
    if "{merge_base}" in step.get("command", ""):
        scope["mergeBase"] = change.merge_base
    return hashlib.sha256(json.dumps(scope, sort_keys=True).encode()).hexdigest()


def _result_path(root: Path, shard: Shard, key: str) -> Path:
    return _common_dir(root) / "work" / "gate" / "results" / shard.step["id"] / f"{key}.json"


def cached(root: Path, shard: Shard, key: str) -> Optional[dict]:
    path = _result_path(root, shard, key)
    if not path.exists():
        return None
    with contextlib.suppress(ValueError, OSError):
        record = json.loads(path.read_text())
        if record.get("outcome") == "pass" and all((root / a).exists() for a in shard.step.get("artifacts", [])):
            return record
    return None


# ---------------------------------------------------------------- running

def _tree_rss_kb(pgid: int) -> int:
    done = subprocess.run(["ps", "-axo", "pgid=,rss="], capture_output=True, text=True)
    total = 0
    for line in done.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == str(pgid):
            total += int(parts[1])
    return total


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


def _last_line(log: Path) -> str:
    with contextlib.suppress(OSError):
        with log.open("rb") as stream:
            stream.seek(max(0, log.stat().st_size - 2048))
            lines = [line for line in stream.read().decode(errors="replace").splitlines() if line.strip()]
            return lines[-1][:140] if lines else ""
    return ""


def run_shard(root: Path, prelude: str, shard: Shard, log: Path, environment: Dict[str, str], position: str,
              print_line=print, stop: Optional[threading.Event] = None) -> Outcome:
    step = shard.step
    stop = stop or threading.Event()
    log.parent.mkdir(parents=True, exist_ok=True)
    lease = None
    if step["class"] == "heavy":
        try:
            lease = heavy.acquire(f"gate {shard.name} in {root.name}", shard.command, need_mb=int(step["expectedRssMb"]),
                                  cancelled=stop.is_set)
        except heavy.Cancelled:
            return Outcome(shard, "cancelled", 130, 0.0, 0, 0.0, log)
    env = dict(environment)
    if lease:
        env[heavy.HELD_ENV] = str(lease.slot + 1)
    started = time.monotonic()
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
                    peak = max(peak, _tree_rss_kb(process.pid))
                    if host_sampling:
                        host_peak = max(host_peak, _host_used_mb() - host_base)
                    if stop.is_set():
                        cancelled = True
                        _kill_group(process.pid)
                        done.wait(10)
                        break
                    if now - started > step["timeoutSeconds"]:
                        timed_out = True
                        _kill_group(process.pid)
                        done.wait(10)
                        break
                    if now >= next_beat:
                        next_beat = now + HEARTBEAT_SECONDS
                        over = " OVER BUDGET" if now - started > step["budgetSeconds"] else ""
                        print_line(f"gate: {position} {shard.name} running {now - started:.0f}s (budget {step['budgetSeconds']}s, "
                                   f"limit {step['timeoutSeconds']}s, rss {peak // 1024} MB){over} | {_last_line(log)}", flush=True)
            except BaseException:
                _kill_group(process.pid)
                raise
            finally:
                # A step owns its process group: anything it left running goes with it.
                _kill_group(process.pid)
    finally:
        if lease:
            lease.release()
    seconds = round(time.monotonic() - started, 1)
    usage = result.get("usage")
    cpu = round(usage.ru_utime + usage.ru_stime, 1) if usage else 0.0
    # Sampling misses very short steps; the largest single process (bytes on macOS) is a floor.
    peak = max(peak, (usage.ru_maxrss // 1024) if usage else 0, host_peak * 1024)
    status = result.get("status", -1)
    code = os.waitstatus_to_exitcode(status) if status != -1 else 124
    if cancelled:
        return Outcome(shard, "cancelled", 130, seconds, peak // 1024, cpu, log)
    if timed_out:
        with log.open("a") as stream:
            stream.write(f"\ngate: TIMEOUT {shard.name} exceeded its hard limit of {step['timeoutSeconds']}s\n")
        return Outcome(shard, "timeout", 124, seconds, peak // 1024, cpu, log)
    return Outcome(shard, "pass" if code == 0 else "fail", code, seconds, peak // 1024, cpu, log)


def _kill_group(pgid: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signal.SIGKILL)


def _excerpt(log: Path) -> str:
    lines = log.read_text(errors="replace").splitlines()[-EXCERPT_LINES:]
    return "\n".join(f"    {line}" for line in lines)


def _record(root: Path, change: Change, key: str, outcome: Outcome) -> None:
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    entry = {"step": outcome.shard.step["id"], "shard": outcome.shard.name, "outcome": outcome.outcome,
             "exit": outcome.exit_code, "seconds": outcome.seconds, "peakRssMb": outcome.peak_rss_mb,
             "cpuSeconds": outcome.cpu_seconds, "key": key, "tree": change.tree, "worktree": root.name,
             "class": outcome.shard.step["class"], "at": now}
    base = _common_dir(root) / "work" / "gate"
    base.mkdir(parents=True, exist_ok=True)
    with (base / "metrics.jsonl").open("a") as stream:
        stream.write(json.dumps(entry) + "\n")
    if outcome.outcome == "pass":
        path = _result_path(root, outcome.shard, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({**entry, "command": outcome.shard.command, "log": str(outcome.log)}, indent=2) + "\n")


def execute(root: Path, config: dict, shards: List[Shard], change: Change, *, force: bool = False,
            only_first_pending: bool = False, require_clean: bool = False) -> bool:
    """Run shards in catalog order, reusing valid passes; stop at the first failure. True when all pass.

    Steps run one after another. Up to `parallelShards` pending shards of one step
    run together, each admitted by the heavy queue on its own memory; the first failing
    shard stops its siblings.
    """
    environment = _check_environment()
    prelude = config["verify"]["prelude"]
    head = _git(root, "rev-parse", "HEAD").strip()
    logs = _git_dir(root) / "work" / "logs" / head[:12]
    total = len(shards)
    started = time.monotonic()
    counts = {"ran": 0, "reused": 0}
    print(f"gate: {total} shards for {head[:12]} (tree {change.tree[:12]}) against {change.base_ref}", flush=True)
    groups: List[List[tuple]] = []
    for number, shard in enumerate(shards, 1):
        if groups and groups[-1][0][1].step is shard.step:
            groups[-1].append((number, shard))
        else:
            groups.append([(number, shard)])
    for group in groups:
        pending = []
        for number, shard in group:
            key = cache_key(root, change, shard)
            hit = None if force else cached(root, shard, key)
            if hit:
                counts["reused"] += 1
                print(f"gate: [{number}/{total}] {shard.name}: reused pass from {hit['at']} ({hit['seconds']}s)", flush=True)
            else:
                pending.append((number, shard, key))
        if not pending:
            continue
        if only_first_pending and counts["ran"]:
            print(f"gate: next pending is {pending[0][1].name}; stopping after one step (gate next)", flush=True)
            return False
        step = pending[0][1].step
        # At most `parallelShards` shards of one step run together (each still admitted by
        # memory); serial suites leave it unset, so timing-sensitive tests never share the host.
        width = 1 if only_first_pending else max(1, int(step.get("parallelShards") or 1))
        pending_runs = [pending[i:i + width] for i in range(0, len(pending), width)]
        for batch in pending_runs:
            failed = _run_batch(root, prelude, batch, logs, environment, total, change, counts)
            if failed:
                number, shard, outcome = failed
                print(f"\n--- {shard.name} failed: {shard.command}\n{_excerpt(outcome.log)}\n"
                      f"gate: stopped at {shard.name}; {total - number} later shards not started. "
                      f"Fix it and rerun: passing shards whose inputs did not change are reused.", flush=True)
                for flake in step.get("knownFlakes", []):
                    print(f"gate: known flake for {step['id']}: {flake}", flush=True)
                return False
            if only_first_pending:
                break
        if require_clean and (_git(root, "rev-parse", "HEAD").strip() != head or workspace_tree(root) != change.tree):
            raise GateError("the head or the worktree changed while steps ran; rerun on a stable tree")
        if only_first_pending:
            remaining = sum(1 for g in groups[groups.index(group) + 1:] for _ in g) + len(pending) - 1
            if remaining:
                print(f"gate: one step run; {remaining} shards may remain (gate next again, or gate run)", flush=True)
                return True
    print(f"gate: all {total} shards passed ({counts['ran']} ran, {counts['reused']} reused) in "
          f"{time.monotonic() - started:.0f}s", flush=True)
    return True


def _run_batch(root: Path, prelude: str, batch: list, logs: Path, environment: Dict[str, str], total: int,
               change: Change, counts: dict) -> Optional[tuple]:
    """Run shards together; return (number, shard, outcome) of the first failure, else None."""
    stop = threading.Event()
    lock = threading.Lock()
    failures: List[tuple] = []

    def one(number: int, shard: Shard, key: str) -> None:
        step = shard.step
        position = f"[{number}/{total}]"
        log = logs / (re.sub(r"[^\w.#-]+", "_", shard.name) + ".log")
        print(f"gate: {position} {shard.name} ({step['class']}, budget {step['budgetSeconds']}s, "
              f"limit {step['timeoutSeconds']}s) log: {log}", flush=True)
        outcome = run_shard(root, prelude, shard, log, environment, position, stop=stop)
        _record(root, change, key, outcome)
        with lock:
            counts["ran"] += 1
            if outcome.outcome == "cancelled":
                print(f"gate: {position} {shard.name}: stopped after a sibling shard failed", flush=True)
                return
            verdict = {"pass": "pass", "fail": f"FAIL (exit {outcome.exit_code})", "timeout": "TIMEOUT"}[outcome.outcome]
            over = " (over budget)" if outcome.seconds > step["budgetSeconds"] else ""
            print(f"gate: {position} {shard.name}: {verdict} in {outcome.seconds}s{over}, peak rss "
                  f"{outcome.peak_rss_mb} MB, cpu {outcome.cpu_seconds}s", flush=True)
            if outcome.outcome != "pass":
                failures.append((number, shard, outcome))
                stop.set()

    threads = [threading.Thread(target=one, args=item, daemon=True) for item in batch]
    for thread in threads:
        thread.start()
    try:
        for thread in threads:
            while thread.is_alive():
                thread.join(0.5)
    except BaseException:
        stop.set()
        for thread in threads:
            thread.join(15)
        raise
    return min(failures, key=lambda item: item[0]) if failures else None


# ---------------------------------------------------------------- entry points used by work land

def verify(root: Path, config: dict, tests: List[str], base_ref: str) -> bool:
    """The landing gate: the full plan on a clean commit (work land)."""
    dirty = _git(root, "status", "--porcelain", "--untracked-files=all").splitlines()
    if dirty:
        raise GateError("commit or remove local changes first; the landing gate checks a commit:\n  " + "\n  ".join(dirty[:20]))
    catalog = load_catalog()
    change = change_for(root, base_ref, tests)
    return execute(root, config, plan(catalog, change), change, require_clean=True)


def _config(root: Path) -> dict:
    return json.loads((root / ".github" / "work.json").read_text())


def _base_ref(root: Path, config: dict, given: Optional[str]) -> str:
    if given:
        return given
    return f"{config['claim']['remote']}/{config['claim']['baseBranch']}"


def _print_plan(shards: List[Shard], change: Change, root: Path, as_json: bool) -> None:
    rows = []
    for shard in shards:
        key = cache_key(root, change, shard)
        hit = cached(root, shard, key)
        rows.append({"shard": shard.name, "class": shard.step["class"], "budgetSeconds": shard.step["budgetSeconds"],
                     "timeoutSeconds": shard.step["timeoutSeconds"], "expectedRssMb": shard.step["expectedRssMb"],
                     "status": "reusable pass" if hit else "pending", "command": shard.command})
    if as_json:
        print(json.dumps({"base": change.base_ref, "mergeBase": change.merge_base, "tree": change.tree,
                          "changed": change.paths, "plan": rows}, indent=2))
        return
    print(f"gate plan: {len(change.paths)} changed paths against {change.base_ref} (merge base {change.merge_base[:12]})")
    for number, row in enumerate(rows, 1):
        print(f"  {number:>2}. {row['shard']:<40} {row['class']:<5} budget {row['budgetSeconds']:>3}s  "
              f"rss~{row['expectedRssMb']:>5} MB  {row['status']}")


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
        step = catalog.get(entries[0]["step"], {})
        summary.append({"shard": shard, "runs": len(entries), "passes": sum(e["outcome"] == "pass" for e in entries),
                        "medianSeconds": statistics.median(seconds), "maxSeconds": max(seconds),
                        "medianPeakRssMb": statistics.median(rss), "maxPeakRssMb": max(rss),
                        "budgetSeconds": step.get("budgetSeconds"), "expectedRssMb": step.get("expectedRssMb")})
    if as_json:
        print(json.dumps(summary, indent=2))
        return 0
    print(f"{'shard':<44} runs  median   max   budget  rss med/max (expected)")
    for row in summary:
        print(f"{row['shard']:<44} {row['runs']:>4} {row['medianSeconds']:>6.0f}s {row['maxSeconds']:>5.0f}s "
              f"{row['budgetSeconds'] or 0:>6}s  {row['medianPeakRssMb']:>5.0f}/{row['maxPeakRssMb']:<5.0f} ({row['expectedRssMb']})")
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
              f"rss~{step['expectedRssMb']:>5} MB{shards}  unlocks {step['unlocks']}\n    when: {when}\n{runs}")
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
    if exit_file.exists():
        job["state"], job["exit"] = ("passed" if exit_file.read_text().strip() == "0" else "failed"), int(exit_file.read_text())
    elif (matches[0].parent / "cancelled").exists():
        job["state"] = "cancelled"
    elif not _alive(job["pid"]):
        job["state"] = "ended without a result"
    else:
        job["state"] = "running"
    job["dir"] = str(matches[0].parent)
    return job


def submit(root: Path, argv: List[str]) -> int:
    """Hand a gate run to the background and return at once: the session keeps working.

    The job runs `gate run` detached in its own process group; heavy shards wait in the
    host queue as usual. `jobs` shows its live state, queue position and last line, `wait`
    returns its result to the requesting session and `cancel` stops it.
    """
    job_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + f"-{os.getpid()}"
    directory = _jobs_dir(root) / job_id
    directory.mkdir(parents=True)
    output = directory / "output.log"
    script = (f"{shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} run "
              + " ".join(shlex.quote(a) for a in argv)
              + f" > {shlex.quote(str(output))} 2>&1; echo $? > {shlex.quote(str(directory / 'exit'))}")
    process = subprocess.Popen(["bash", "-c", script], cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    session = os.environ.get("WORK_SESSION_ID") or os.environ.get("PI_SESSION_ID") or ""
    (directory / "job.json").write_text(json.dumps({
        "id": job_id, "pid": process.pid, "worktree": str(root), "session": session, "args": argv,
        "submittedAt": datetime.now(timezone.utc).isoformat(timespec="seconds")}, indent=2) + "\n")
    print(f"gate: submitted job {job_id} (pid {process.pid}); keep working.\n"
          f"  progress: scripts/tron gate jobs\n  result:   scripts/tron gate wait {job_id}\n"
          f"  cancel:   scripts/tron gate cancel {job_id}")
    return 0


def jobs(root: Path) -> int:
    directory = _jobs_dir(root)
    queued = {item.get("pid"): position for position, item in enumerate(heavy.waiters(heavy._directory()), 1)}
    for path in sorted(directory.glob("*/job.json")) if directory.is_dir() else []:
        job = _job(root, path.parent.name)
        if job["state"] != "running" and job["worktree"] != str(root):
            continue
        output = Path(job["dir"]) / "output.log"
        last = _last_line(output)
        # The waiting runner is a child of the job's shell; its heavy ticket names its own pid.
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
    while job["state"] == "running":
        time.sleep(1)
        text = output.read_text(errors="replace") if output.exists() else ""
        if len(text) > printed:
            print(text[printed:], end="", flush=True)
            printed = len(text)
        job = _job(root, job_id)
    text = output.read_text(errors="replace") if output.exists() else ""
    print(text[printed:], end="")
    print(f"gate: job {job['id']} {job['state']}")
    return int(job.get("exit", 1)) if job["state"] in ("passed", "failed") else 1


def cancel(root: Path, job_id: str) -> int:
    job = _job(root, job_id)
    if job["state"] != "running":
        print(f"gate: job {job['id']} already {job['state']}")
        return 0
    (Path(job["dir"]) / "cancelled").touch()
    # The job owns its process group; the runner's own step groups are killed by its TERM handler.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(job["pid"], signal.SIGTERM)
    print(f"gate: cancelled job {job['id']}")
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
    sub = commands.add_parser("submit", help="hand `gate run [args]` to the background and return at once")
    sub.add_argument("args", nargs=argparse.REMAINDER)
    commands.add_parser("jobs", help="background gate jobs with live state and heavy-queue position")
    for name in ("wait", "cancel"):
        commands.add_parser(name, help=f"{name} a background gate job").add_argument("job")
    sub = commands.add_parser("report", help="wall time and peak RSS per shard from recorded runs")
    sub.add_argument("--json", action="store_true")
    commands.add_parser("catalog", help="print the step catalog")
    args = parser.parse_args(argv)
    root = Path(_git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
    try:
        if args.action == "report":
            return report(root, args.json)
        if args.action == "catalog":
            return catalog_table()
        if args.action == "submit":
            return submit(root, args.args)
        if args.action == "jobs":
            return jobs(root)
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
        ok = execute(root, config, shards, change, force=getattr(args, "force", False), only_first_pending=args.action == "next")
        return 0 if ok else 1
    except GateError as error:
        print(f"gate: {error}", file=sys.stderr)
        return 2


def _named(catalog: dict, change: Change, planned: List[Shard], names: List[str]) -> List[Shard]:
    """Named steps (with their planned prerequisites first), even when the change would not select them."""
    steps = {step["id"]: step for step in catalog["steps"]}
    wanted: List[Shard] = []
    for name in names:
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
            wanted.extend(s for s in planned if s.step["id"] == prerequisite and s not in wanted)
        wanted.extend(s for s in matched if s not in wanted)
    return wanted


def _terminate(_signal, _frame) -> None:
    # Cancellation (gate cancel, a closed terminal): unwind so the running step's group is killed.
    raise KeyboardInterrupt


if __name__ == "__main__":
    for received in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(received, _terminate)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("gate: interrupted; the running step was stopped", file=sys.stderr)
        sys.exit(130)
