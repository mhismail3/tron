"""`gate report`: what verification cost over a time window, and why (README.md#report, #1103).

Reads the ledgers (ledger.py) and answers, for any window:

- where shard time went, by step, by tier and by the reason each shard ran;
- how much time produced no pass, and which cache keys failed and later passed
  unchanged (flake or load evidence, never code);
- heavy-queue wait, its causes, and how much of it happened while no gate heavy
  shard was running (admission blind to real holders);
- reuse: shards reused versus run per gate run;
- landing: landings, loop-backs and the time from enqueue to merge.

Why a shard ran is reconstructed from the recorded trees, so it is exact for any
row: its step's input tree is recomputed from git and compared with the same
worktree's previous pass of that shard; changed input paths that `origin/main`
touched in between are attributed to main.
"""
from __future__ import annotations

import collections
import fnmatch
import hashlib
import json
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional

import flakes
import ledger

REASONS = (
    ("new-shard", "first run of this selection in this worktree"),
    ("inputs:branch", "the branch's own edits changed its inputs"),
    ("inputs:mixed", "inputs changed by both main and the branch"),
    ("rerun-same-key", "retry of a key that failed, timed out or was cancelled"),
    ("inputs:main-only", "only main's merge changed its inputs"),
    ("first-ever", "first run of the step anywhere"),
    ("duplicate-key", "the same key had already passed (concurrent run or --force)"),
    ("worktree-scope", "cacheScope forbade reusing an identical pass from another worktree"),
    ("key-differs-xwt", "identical inputs passed in another worktree under a different command or key"),
    ("inputs:docs-only", "inputs differed only in *.md or docs/"),
    ("command-churn", "identical inputs, different rendered command"),
    ("catalog-or-command", "same inputs in this worktree, but the key changed (catalog, command or toolchain)"),
)


def parse_time(value: str, now: Optional[datetime] = None) -> datetime:
    """An ISO time, or a span back from now such as 90m, 12h or 3d."""
    now = now or datetime.now(timezone.utc)
    match = re.fullmatch(r"(\d+)([mhd])", value.strip())
    if match:
        amount, unit = int(match.group(1)), match.group(2)
        unit_name = {"m": "minutes", "h": "hours", "d": "days"}[unit]
        return now - timedelta(**{unit_name: amount})
    parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _pct(values: List[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


class _Git:
    def __init__(self, root: Path):
        self.root = root
        self.cache: Dict[tuple, Dict[str, str]] = {}

    def run(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True).stdout

    def inputs(self, tree: str, patterns: List[str]) -> Dict[str, str]:
        key = (tree, tuple(patterns))
        if key not in self.cache:
            listing = self.run("ls-tree", "-r", "--full-tree", tree, "--", *patterns)
            self.cache[key] = {line.split("\t", 1)[1]: line.split()[2] for line in listing.splitlines() if "\t" in line}
        return self.cache[key]


def _main_log(git: _Git, base_ref: str, since: datetime) -> List[tuple]:
    out = git.run("log", base_ref, f"--since={(since - timedelta(days=2)).isoformat()}", "--first-parent",
                  "--name-only", "--format=@@%cI")
    log = []
    for block in out.split("@@")[1:]:
        lines = [line for line in block.splitlines() if line.strip()]
        if lines:
            log.append((_ts(lines[0]), set(lines[1:])))
    return log


def _classify(rows: List[dict], catalog: Dict[str, dict], git: _Git, main_log: List[tuple]) -> None:
    passes_by_step: Dict[str, List[dict]] = collections.defaultdict(list)
    previous: Dict[tuple, dict] = {}
    attempts: Dict[tuple, List[str]] = collections.defaultdict(list)
    for row in rows:
        step = catalog.get(row["step"], {})
        files = git.inputs(row["tree"], step.get("inputs", ["."]))
        row["_inputs"] = hashlib.sha256(json.dumps(sorted(files.items())).encode()).hexdigest() if files else None
        earlier = passes_by_step[row["step"]]
        prev = previous.get((row["worktree"], row["shard"]))
        if any(outcome != "pass" for outcome in attempts[(row["worktree"], row["key"])]):
            reason = "rerun-same-key"
        elif any(p["key"] == row["key"] for p in earlier):
            reason = "duplicate-key"
        elif not earlier:
            reason = "first-ever"
        elif not prev:
            same = [p for p in earlier if p["_inputs"] == row["_inputs"] and row["_inputs"] and p["shard"] == row["shard"]]
            if same and step.get("cacheScope") in ("worktree", "source"):
                reason = "worktree-scope"
            elif same:
                reason = "key-differs-xwt"
            else:
                reason = "new-shard"
        elif prev["_inputs"] == row["_inputs"]:
            reason = "catalog-or-command"
        else:
            before, after = git.inputs(prev["tree"], step.get("inputs", ["."])), files
            changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
            if not changed:
                reason = "command-churn"
            elif all(p.endswith(".md") or "/docs/" in p or p.startswith("docs/") for p in changed):
                reason = "inputs:docs-only"
            else:
                start = _ts(row["at"]) - timedelta(seconds=row["seconds"])
                touched = set()
                for when, names in main_log:
                    if _ts(prev["at"]) - timedelta(minutes=5) <= when <= start:
                        touched |= names
                from_main = changed & touched
                reason = "inputs:main-only" if from_main == changed else "inputs:mixed" if from_main else "inputs:branch"
        row["reason"] = reason
        attempts[(row["worktree"], row["key"])].append(row["outcome"])
        if row["outcome"] == "pass":
            earlier.append(row)
            previous[(row["worktree"], row["shard"])] = row


def _concurrency(rows: List[dict]) -> tuple:
    """Seconds spent at each level of gate heavy concurrency, and the running intervals."""
    events = []
    for row in rows:
        if row["class"] == "heavy":
            end = _ts(row["at"])
            events += [(end - timedelta(seconds=row["seconds"]), 1), (end, -1)]
    events.sort()
    level, last, at_level, peak = 0, None, collections.Counter(), 0
    intervals = []  # (start, end, level)
    for when, delta in events:
        if last is not None and when > last:
            at_level[level] += (when - last).total_seconds()
            intervals.append((last, when, level))
        level += delta
        peak = max(peak, level)
        last = when
    return at_level, intervals, peak


def _idle_overlap(start: datetime, end: datetime, intervals: List[tuple]) -> float:
    """Seconds of [start, end) during which no gate heavy shard ran."""
    busy = 0.0
    for a, b, level in intervals:
        if level > 0 and b > start and a < end:
            busy += (min(b, end) - max(a, start)).total_seconds()
    return max(0.0, (end - start).total_seconds() - busy)


def _job_waits(common: Path, rows: List[dict], since: datetime, until: datetime) -> tuple:
    """Legacy queue wait (rows without queuedSeconds): gaps before heavy shards inside background jobs,
    plus the wait reasons the jobs' logs printed."""
    waits, reasons = [], collections.Counter()
    jobs = common / "work" / "gate" / "jobs"
    for directory in sorted(jobs.iterdir()) if jobs.is_dir() else []:
        try:
            job = json.loads((directory / "job.json").read_text())
        except (OSError, ValueError):
            continue
        begin = _ts(job["submittedAt"])
        if not since <= begin <= until:
            continue
        finish = (datetime.fromtimestamp((directory / "exit").stat().st_mtime, timezone.utc)
                  if (directory / "exit").exists() else until)
        name = Path(job["worktree"]).name
        mine = sorted((r for r in rows if r["worktree"] == name and begin <= _ts(r["at"]) - timedelta(seconds=r["seconds"])
                       and _ts(r["at"]) <= finish + timedelta(seconds=5)), key=lambda r: r["at"])
        log = (directory / "output.log").read_text(errors="replace") if (directory / "output.log").exists() else ""
        for line in log.splitlines():
            if line.startswith("heavy-run: next, waiting for memory"):
                reasons["memory"] += 1
            elif line.startswith("heavy-run: next, waiting for host load") or "waiting for cpu" in line.lower():
                reasons["load-or-cpu"] += 1
            elif line.startswith("heavy-run: queued at position"):
                reasons["queued-behind"] += 1
        previous_end = begin
        for row in mine:
            start = _ts(row["at"]) - timedelta(seconds=row["seconds"])
            gap = (start - previous_end).total_seconds()
            if row["class"] == "heavy" and gap > 3 and "queuedSeconds" not in row:
                waits.append((previous_end, start, gap))
            previous_end = _ts(row["at"])
    return waits, reasons


def build(root: Path, catalog_steps: List[dict], since: datetime, until: datetime, exclude: List[str],
          base_ref: str = "origin/main", heavy_events: Optional[Path] = None) -> dict:
    common = ledger.common_dir(root)
    catalog = {step["id"]: step for step in catalog_steps}
    every = [r for r in ledger.rows(common / "work" / "gate" / "metrics.jsonl") if "at" in r and "shard" in r]
    window = [r for r in every if since <= _ts(r["at"]) <= until]
    excluded = collections.Counter()
    rows = []
    for row in window:
        if row.get("purpose", "work") != "work":
            excluded[f"purpose:{row['purpose']}"] += 1
        elif any(fnmatch.fnmatch(row.get("worktree", ""), pattern) for pattern in exclude):
            excluded["excluded-worktree"] += 1
        elif not re.fullmatch(r"[0-9a-f]{64}", str(row.get("key", ""))) or row["step"] not in catalog:
            excluded["not-a-gate-execution"] += 1
        else:
            rows.append(row)
    # Ledger order is completion order: a retry always follows the failure it retries.
    git = _Git(root)
    _classify(rows, catalog, git, _main_log(git, base_ref, since))
    total = sum(r["seconds"] for r in rows) or 1.0

    def bucket(key) -> Dict[str, dict]:
        out: Dict[str, dict] = collections.defaultdict(lambda: {"runs": 0, "seconds": 0.0})
        for row in rows:
            entry = out[key(row)]
            entry["runs"] += 1
            entry["seconds"] += row["seconds"]
        return {k: {"runs": v["runs"], "seconds": round(v["seconds"]), "share": round(v["seconds"] / total, 3)}
                for k, v in sorted(out.items(), key=lambda kv: -kv[1]["seconds"])}

    # Shards that ran XCTest cases: wall time beyond the cases themselves (#1109).
    overhead: Dict[str, List[float]] = collections.defaultdict(list)
    for row in rows:
        if row.get("testSeconds") and row["outcome"] == "pass":
            overhead[row["step"]].append(round(row["seconds"] - row["testSeconds"], 1))
    tiers = {}
    for tier in sorted({r.get("tier") or catalog[r["step"]].get("tier", "?") for r in rows}):
        walls = [r["seconds"] for r in rows if (r.get("tier") or catalog[r["step"]].get("tier", "?")) == tier]
        tiers[tier] = {"runs": len(walls), "seconds": round(sum(walls)), "p50": _pct(walls, 0.5), "p90": _pct(walls, 0.9)}
    attempts: Dict[tuple, List[str]] = collections.defaultdict(list)
    for row in rows:
        attempts[(row["worktree"], row["key"])].append(row["outcome"])
    flake_keys = []
    for (worktree, key), outcomes in attempts.items():
        if "pass" in outcomes and any(o in ("fail", "timeout") for o in outcomes[:outcomes.index("pass")]):
            shard = next(r["shard"] for r in rows if r["key"] == key)
            flake_keys.append({"worktree": worktree, "shard": shard, "outcomes": outcomes})
    failures = sum(1 for r in rows if r["outcome"] in ("fail", "timeout"))
    # Per test: how often it failed, and how often such a failure later passed unchanged.
    per_test: Dict[str, Dict[str, int]] = collections.defaultdict(lambda: {"failed": 0, "flaky": 0})
    open_failures: Dict[str, List[dict]] = {}
    infra = 0  # timeouts with no failing test that passed on their classification rerun
    for row in rows:
        if row["outcome"] in ("fail", "timeout"):
            for test in row.get("failedTests") or []:
                per_test[test]["failed"] += 1
            open_failures.setdefault(row["key"], []).append(row)
        elif row["outcome"] == "pass" and row["key"] in open_failures:
            failed = open_failures.pop(row["key"])
            for test in {t for r in failed for t in r.get("failedTests") or []}:
                per_test[test]["flaky"] += 1
            infra += bool(row.get("classifyRerun")) and any(r["outcome"] == "timeout" and not r.get("failedTests")
                                                            for r in failed)
    by_class = collections.Counter(r.get("failureClass") or ("timeout" if r["outcome"] == "timeout" else "unclassified")
                                   for r in rows if r["outcome"] in ("fail", "timeout"))
    flaky_failures = sum(sum(1 for o in f["outcomes"][:f["outcomes"].index("pass")] if o in ("fail", "timeout")) for f in flake_keys)

    at_level, intervals, peak = _concurrency(rows)
    span = sum(at_level.values()) or 1.0
    measured = [(_ts(r["at"]) - timedelta(seconds=r["seconds"] + r["queuedSeconds"]),
                 _ts(r["at"]) - timedelta(seconds=r["seconds"]), r["queuedSeconds"])
                for r in rows if r["class"] == "heavy" and r.get("queuedSeconds")]
    legacy, wait_reasons = _job_waits(common, rows, since, until)
    waits = measured + legacy
    wait_total = sum(w[2] for w in waits)
    idle = sum(_idle_overlap(a, b, intervals) for a, b, _ in waits)
    # The heavy ledger (heavy.py) also sees direct holders (`tron-heavy run`, leased vitest
    # and iOS runs): waits while it shows no holder at all were waits behind nothing.
    holds = []
    for row in (ledger.rows(heavy_events) if heavy_events else []):
        if row.get("event") == "release" and "at" in row and since <= _ts(row["at"]) <= until:
            end = _ts(row["at"])
            holds.append((end - timedelta(seconds=float(row.get("heldSeconds") or 0)), end, row.get("kind", "direct")))
    any_level = [(a, b, 1) for a, b, _ in holds]
    idle_any = sum(_idle_overlap(a, b, any_level) for a, b, _ in waits) if holds else None
    held_by_kind = collections.Counter()
    for a, b, kind in holds:
        held_by_kind[kind] += (b - a).total_seconds()

    runs = [r for r in ledger.rows(common / "work" / "gate" / "runs.jsonl")
            if "at" in r and since <= _ts(r["at"]) <= until and r.get("purpose", "work") == "work"]
    ran = sum(r.get("ran", 0) for r in runs)
    reused = sum(r.get("reused", 0) for r in runs)

    lands = [r for r in ledger.rows(common / "work" / "land" / "events.jsonl")
             if "at" in r and since <= _ts(r["at"]) <= until and r.get("purpose", "work") == "work"]
    landing = collections.Counter(r["event"] for r in lands)
    queue_waits = [float(r.get("waitedSeconds") or 0) for r in lands if r["event"] == "turn"]
    durations = []
    started: Dict[str, datetime] = {}
    for row in lands:
        if row["event"] == "start":
            started[row.get("branch", "")] = _ts(row["at"])
        elif row["event"] == "merged" and row.get("branch", "") in started:
            durations.append((_ts(row["at"]) - started.pop(row["branch"])).total_seconds())

    return {
        "window": [since.isoformat(), until.isoformat()],
        "records": {"inWindow": len(window), "analysed": len(rows), "excluded": dict(excluded)},
        "worktrees": len({r["worktree"] for r in rows}),
        "shardSeconds": round(total if rows else 0),
        "cpuSeconds": round(sum(r.get("cpuSeconds", 0) for r in rows)),
        "byOutcome": bucket(lambda r: r["outcome"]),
        "nonPassShare": round(sum(r["seconds"] for r in rows if r["outcome"] != "pass") / total, 3),
        "overBudget": sum(1 for r in rows if r["seconds"] > catalog[r["step"]]["budgetSeconds"]),
        "byReason": bucket(lambda r: r["reason"]),
        "byStep": bucket(lambda r: r["step"]),
        "byTier": tiers,
        "testOverhead": {step: {"shards": len(v), "p50": _pct(v, 0.5), "p90": _pct(v, 0.9)} for step, v in overhead.items()},
        "flakes": {"failures": failures, "sameKeyFailThenPass": flaky_failures, "keys": flake_keys,
                   "byClass": dict(by_class), "infraTimeouts": infra,
                   "tests": {t: v for t, v in sorted(per_test.items(), key=lambda kv: -kv[1]["flaky"])},
                   "quarantine": {"active": len(flakes.active(common)), "expired": flakes.expired(common),
                                  "unowned": [e["test"] for e in flakes.entries(common) if not e.get("issue")]}},
        "queue": {"waits": len(waits), "seconds": round(wait_total), "p50": _pct([w[2] for w in waits], 0.5),
                  "p90": _pct([w[2] for w in waits], 0.9), "max": max((w[2] for w in waits), default=0),
                  "whileNoGateHeavyShardRan": round(idle), "idleShare": round(idle / wait_total, 3) if wait_total else 0.0,
                  "measuredRows": len(measured), "legacyJobGaps": len(legacy), "waitLineReasons": dict(wait_reasons),
                  "whileNoHeavyHolder": round(idle_any) if idle_any is not None else None,
                  "heldSecondsByKind": {k: round(v) for k, v in held_by_kind.items()}},
        "heavyConcurrency": {"peak": peak, "share": {str(k): round(v / span, 3) for k, v in sorted(at_level.items())}},
        "reuse": {"runs": len(runs), "ran": ran, "reused": reused,
                  "share": round(reused / (ran + reused), 3) if ran + reused else None},
        "landing": {"events": dict(landing), "loopBacks": landing.get("loop-back", 0), "merged": landing.get("merged", 0),
                    "startToMergeP50": _pct(durations, 0.5), "startToMergeP90": _pct(durations, 0.9),
                    "queueWaitP50": _pct(queue_waits, 0.5), "queueWaitP90": _pct(queue_waits, 0.9)},
    }


def render(summary: dict) -> str:
    lines = [f"gate report {summary['window'][0]} .. {summary['window'][1]}",
             f"  {summary['records']['analysed']} shard runs in {summary['worktrees']} worktrees, "
             f"{summary['shardSeconds']} s shard time, {summary['cpuSeconds']} CPU-s"
             + (f"; excluded {summary['records']['excluded']}" if summary["records"]["excluded"] else "")]
    names = dict(REASONS)
    lines.append("why shards ran:")
    for reason, entry in summary["byReason"].items():
        lines.append(f"  {reason:<20} {entry['runs']:>5} runs {entry['seconds']:>7} s {entry['share']:>6.1%}  {names.get(reason, '')}")
    lines.append("outcomes: " + ", ".join(f"{k} {v['runs']} ({v['seconds']} s)" for k, v in summary["byOutcome"].items())
                 + f"; no-pass share {summary['nonPassShare']:.1%}; over budget {summary['overBudget']}")
    flakes = summary["flakes"]
    lines.append(f"flakes: {flakes['sameKeyFailThenPass']} of {flakes['failures']} failures or timeouts later passed on "
                 f"the same key ({len(flakes['keys'])} keys)")
    for entry in flakes["keys"][:10]:
        lines.append(f"  {entry['shard']} in {entry['worktree']}: {' '.join(entry['outcomes'])}")
    lines.append(f"  failure classes {flakes['byClass']}; infra timeouts {flakes['infraTimeouts']}; quarantine "
                 f"{flakes['quarantine']['active']} active, {len(flakes['quarantine']['expired'])} expired, "
                 f"unowned {flakes['quarantine']['unowned']}")
    for test, entry in list(flakes["tests"].items())[:10]:
        if entry["flaky"]:
            lines.append(f"  flaky test {test}: {entry['flaky']} of {entry['failed']} failures passed unchanged")
    lines.append("by tier: " + ", ".join(f"{t} {v['runs']} runs {v['seconds']} s p50 {v['p50']:.0f}s p90 {v['p90']:.0f}s"
                                         for t, v in summary["byTier"].items()))
    if summary["testOverhead"]:
        lines.append("test overhead (wall minus XCTest case time): " + ", ".join(
            f"{step} {v['shards']} shards p50 {v['p50']:.0f}s p90 {v['p90']:.0f}s" for step, v in summary["testOverhead"].items()))
    lines.append("by step:")
    for step, entry in list(summary["byStep"].items())[:15]:
        lines.append(f"  {step:<26} {entry['runs']:>5} runs {entry['seconds']:>7} s {entry['share']:>6.1%}")
    queue = summary["queue"]
    lines.append(f"heavy queue: {queue['waits']} waits, {queue['seconds']} s (p50 {queue['p50']:.0f}s, p90 {queue['p90']:.0f}s, "
                 f"max {queue['max']:.0f}s); {queue['whileNoGateHeavyShardRan']} s ({queue['idleShare']:.1%}) while no gate "
                 f"heavy shard ran; reasons {queue['waitLineReasons']}")
    if queue.get("whileNoHeavyHolder") is not None:
        lines.append(f"  heavy ledger: {queue['whileNoHeavyHolder']} s of that wait had no heavy holder of any kind; "
                     f"held seconds by kind {queue['heldSecondsByKind']}")
    lines.append("gate heavy concurrency share: " + ", ".join(f"{k}: {v:.0%}" for k, v in summary["heavyConcurrency"]["share"].items())
                 + f"; peak {summary['heavyConcurrency']['peak']}")
    reuse = summary["reuse"]
    lines.append(f"reuse: {reuse['reused']} reused / {reuse['ran']} ran over {reuse['runs']} gate runs"
                 + (f" ({reuse['share']:.0%})" if reuse["share"] is not None else ""))
    landing = summary["landing"]
    lines.append(f"landing: {landing['merged']} merged, {landing['loopBacks']} loop-backs, start→merge p50 "
                 f"{landing['startToMergeP50']:.0f}s p90 {landing['startToMergeP90']:.0f}s; land queue wait p50 "
                 f"{landing['queueWaitP50']:.0f}s p90 {landing['queueWaitP90']:.0f}s; events {landing['events']}")
    return "\n".join(lines)
