#!/usr/bin/env python3
"""Read-only audit of agent session logs: where worker wall time went (verification, setup, waiting, model) and each check-in."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

RESULT = re.compile(r'"timestamp": ?"([^"]+)", ?"message": ?\{"role": ?"toolResult", ?"toolCallId": ?"([^"]+)"')
MODEL_GAP_CAP = 900.0

RULES = [
    ("wait: sleep or poll", re.compile(r"(^|[;&|(]\s*|\bdo\s+)sleep \d|\bwhile\b.*\bsleep\b|\buntil\b.*\bsleep\b", re.S)),
    ("verify --plan", re.compile(r"tron verify\b[^\n;|&]*--plan")),
    ("verify --batch", re.compile(r"tron verify\b[^\n;|&]*--batch")),
    ("verify (mini)", re.compile(r"tron verify\b[^\n;|&]*(--ios-host[ =]mini|--gateway-host[ =]mini)")),
    ("verify (local or pool)", re.compile(r"tron verify\b|tools/verify/verify\.py")),
    ("ios test or build", re.compile(r"tron-ios-test|tron test ios|ios-gateway-e2e-test|xcodebuild|tron-xcodebuild|tron-profile|ios-mac-terminal-journey")),
    ("mac test or build", re.compile(r"tron test mac|verify-mac-install|tron mac ")),
    ("gateway tests", re.compile(r"tron test gateway|vitest|npm (run )?test|tools/verify/gateway\.py|tron mutate|node --test")),
    ("tooling tests", re.compile(r"tron test tooling|python3 [^\n;|&]*test-[\w-]+\.py|bash [^\n;|&]*test-[\w-]+\.sh")),
    ("typecheck or lint", re.compile(r"npm run (check|lint|build)|\btsc\b|tron layers|tron ownership|tron tidy|tron docs")),
    ("setup: npm ci", re.compile(r"npm (--prefix \S+ )?(ci|install)\b|npm [^\n;|&]*\bci\b")),
    ("setup: worktree", re.compile(r"git worktree add")),
    ("dev gateway", re.compile(r"tron dev (start|restart|stop|handoff)")),
    ("git or gh", re.compile(r"^\s*(cd \S+ && )?(git|gh) |tron work ")),
]
VERIFICATION = {"verify (mini)", "verify (local or pool)", "verify --batch", "ios test or build", "mac test or build",
                "gateway tests", "tooling tests", "typecheck or lint"}


def classify(command: str) -> str:
    for name, pattern in RULES:
        if pattern.search(command):
            return name
    return "other shell"


def stamp(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def quantile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(q * (len(ordered) - 1)))] if ordered else float("nan")


def scan(path: Path):
    calls: dict[str, tuple[float, str, str]] = {}
    spans, checkins = [], []
    first = last = None
    last_result = None
    model = 0.0
    task = None
    with path.open(errors="replace") as handle:
        for line in handle:
            head = line[:600]
            found = RESULT.search(head)
            if found:
                when = stamp(found.group(1))
                last = when
                last_result = when
                call = calls.pop(found.group(2), None)
                if call:
                    spans.append((call[1], call[2], when - call[0], call[0]))
                continue
            if '"role": "assistant"' not in head and '"role":"assistant"' not in head:
                if task is None and '"role": "user"' in head and "kind: brief" in line[:1200]:
                    task = "worker"
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            when = stamp(entry["timestamp"])
            first = first or when
            last = when
            if last_result is not None:
                model += min(when - last_result, MODEL_GAP_CAP)
                last_result = None
            for part in entry["message"].get("content") or []:
                if not isinstance(part, dict) or part.get("type") != "toolCall":
                    continue
                name, arguments = part.get("name", ""), part.get("arguments") or {}
                if name.lower() == "bash":
                    command = str(arguments.get("command", ""))
                    calls[part["id"]] = (when, classify(command), command[:800])
                elif name == "checkin":
                    checkins.append((entry["timestamp"], arguments.get("step", ""), arguments.get("done", ""),
                                     arguments.get("next", ""), arguments.get("blocker", "")))
                elif name == "bg_wait":
                    calls[part["id"]] = (when, "wait: bg_wait", "")
                elif name == "subagent":
                    calls[part["id"]] = (when, "subagent call", str(arguments.get("agent") or arguments.get("workflow") or arguments.get("action") or ""))
                else:
                    calls[part["id"]] = (when, "other tool", name)
    return {"first": first, "last": last, "spans": spans, "checkins": checkins, "model": model, "worker": task == "worker"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sessions", type=Path, help="a Pi session directory (top level *.jsonl only)")
    parser.add_argument("--since", default="2026-10-25", help="ISO date; sessions modified earlier are skipped")
    parser.add_argument("--checkins", type=Path, help="write every check-in as TSV here")
    parser.add_argument("--slow", type=Path, help="write every verification or waiting span of 60 s or more as TSV here")
    parser.add_argument("--workers-only", action="store_true", help="count only sessions that began with a Home brief")
    args = parser.parse_args()
    since = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc).timestamp()

    by_kind: dict[str, list[float]] = defaultdict(list)
    model = 0.0
    sessions = 0
    rows, slow = [], []
    for path in sorted(args.sessions.glob("*.jsonl")):
        if path.stat().st_mtime < since:
            continue
        data = scan(path)
        if data["first"] is None or (args.workers_only and not data["worker"]):
            continue
        sessions += 1
        model += data["model"] if data["first"] >= since else 0.0
        for kind, detail, seconds, started in data["spans"]:
            if started < since:
                continue
            by_kind[kind].append(seconds)
            if (kind in VERIFICATION or kind.startswith("wait")) and seconds >= 60:
                slow.append((datetime.fromtimestamp(started, timezone.utc).isoformat(), path.name[:24], kind, f"{seconds:.0f}", detail.replace("\n", " ").replace("\t", " ")))
        for when, step, done, following, blocker in data["checkins"]:
            if stamp(when) < since:
                continue
            rows.append((when, path.name[:24], *[text.replace("\n", " ").replace("\t", " ") for text in (step, done, following, blocker)]))
    if args.checkins:
        args.checkins.write_text("".join("\t".join(row) + "\n" for row in sorted(rows)))
    if args.slow:
        args.slow.write_text("".join("\t".join(row) + "\n" for row in sorted(slow)))

    tool_total = sum(sum(values) for values in by_kind.values())
    total = tool_total + model
    print(f"sessions: {sessions}  check-ins: {len(rows)}  tool hours: {tool_total / 3600:.1f}  model hours (gaps capped at {MODEL_GAP_CAP:.0f} s): {model / 3600:.1f}")
    print(f"{'kind':26s} {'calls':>6s} {'p50 s':>8s} {'p95 s':>8s} {'max s':>8s} {'hours':>8s} {'share':>6s}")
    for kind, values in sorted(by_kind.items(), key=lambda item: -sum(item[1])):
        print(f"{kind:26s} {len(values):6d} {quantile(values, 0.5):8.1f} {quantile(values, 0.95):8.1f} {max(values):8.0f} {sum(values) / 3600:8.1f} {sum(values) / total:6.1%}")
    print(f"{'model (thinking, writing)':26s} {'':6s} {'':8s} {'':8s} {'':8s} {model / 3600:8.1f} {model / total:6.1%}")
    verification = sum(sum(values) for kind, values in by_kind.items() if kind in VERIFICATION)
    waiting = sum(sum(values) for kind, values in by_kind.items() if kind.startswith("wait"))
    setup = sum(sum(values) for kind, values in by_kind.items() if kind.startswith("setup"))
    print(f"\nverification commands: {verification / 3600:.1f} h ({verification / total:.1%}); explicit waiting: {waiting / 3600:.1f} h ({waiting / total:.1%}); "
          f"setup: {setup / 3600:.1f} h ({setup / total:.1%})")
    heavy = Counter()
    for row in rows:
        if row[2].startswith("Heavy start"):
            heavy["Heavy start"] += 1
        if row[2].startswith("Heavy done"):
            heavy["Heavy done"] += 1
        if re.search(r"\bwait|\bbusy\b|\bqueue|\blease\b|exit 7[35]|\bcontend", " ".join(row[2:]), re.I):
            heavy["check-ins that mention waiting, queue, lease, busy or contention"] += 1
        if row[5]:
            heavy["check-ins with a blocker"] += 1
    print("check-in markers:", dict(heavy))
    return 0


if __name__ == "__main__":
    sys.exit(main())
