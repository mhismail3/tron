#!/usr/bin/env python3
"""scripts/tron health: outcome and diagnostic health signals of one commit, diffed against a baseline.

Definitions, anchors and what each signal is validated for: docs/HEALTH.md. Read-only; never a gate (the
exit status reflects only usage or Git errors). Diagnostics come from the commit's Git objects and history,
so they are deterministic. Outcomes also read, only when asked: GitHub issues (`--github`, via `gh`),
this Mac's retained verify/batch reports (`--evidence`), the Mac deploy log (`--deploy-log`) and the Home
session JSONL (`--home-sessions`). Those are local observations and are labelled as such.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import math
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ownership"))
import metrics  # noqa: E402  (the one inventory and classification authority)
import ownership  # noqa: E402  (the one module authority)

BASELINE = "356b00a3b"
DAYS = 30
DAY = 86400
SCORED = metrics.HAND_WRITTEN + metrics.SEPARATE
FIX = re.compile(r"\bfix(e[sd])?\b|^revert\b", re.IGNORECASE)
ISSUE_REF = re.compile(r"#(\d{3,5})")
RED = re.compile(r"\bred\b|\bflak|\bfails? on (main|base)\b|\btimed? ?out\b|\btimeouts?\b|\bunder load\b|"
                 r"\bload-sensitive\b|\bintermittent|\bnondetermin|\bspurious|\bstall(s|ed)?\b", re.IGNORECASE)
BROAD = 40
HASH_PIN = re.compile(rb"\b[0-9a-f]{64}\b|promptHash")
CHASE = re.compile(r"\b(where|what'?s left|status|stuck|still running|why (didn|did|is|are|hasn)\w*|did you|"
                   r"what happened|any update)\b", re.IGNORECASE)


def git(*args: str, data: bytes | None = None) -> str:
    return metrics.git(*args, data=data).decode("utf-8", "surrogateescape")


def clamp(value: float) -> float:
    return max(0.0, min(1.0, value))


def file_score(lines: int, commits: int, fixes: int, cross: int) -> float:
    """10 = small, quiet, changes alone, rarely fixed; 0 = huge, constantly changed, coupled, mostly fixed.
    Weights follow the backtest in docs/HEALTH.md: size and churn predict later rework best, prior fixes least."""
    size = 3.5 * clamp(math.log(max(lines, 1) / 300) / math.log(2500 / 300))
    churn = 3.0 * clamp(math.log1p(commits) / math.log1p(30))
    coupling = 2.0 * (cross / commits if commits else 0) * clamp(commits / 5)
    rework = 1.5 * clamp(fixes / 6)
    return round(10 - size - churn - coupling - rework, 1)


def commits_in(rev: str, start: int, end: int, renames: bool = False) -> list[dict]:
    """Non-merge commits reachable from rev with committer time in (start, end], oldest first."""
    raw = git("log", "--reverse", "--no-merges", "-M" if renames else "--no-renames", "--name-status",
              "--format=%x01%H %ct %s", rev)
    out = []
    for block in raw.split("\x01")[1:]:
        head, _, rest = block.partition("\n")
        sha, stamp, subject = (head.split(" ", 2) + [""])[:3]
        if start < int(stamp) <= end:
            changes = [line.split("\t") for line in rest.splitlines() if "\t" in line]
            out.append({"sha": sha, "time": int(stamp), "subject": subject, "fix": bool(FIX.search(subject)),
                        "changes": changes, "paths": [c[-1] for c in changes]})
    return out


def modules_of(sha: str):
    result, _ = ownership.check(sha)
    owner = {path: name for name, mod in result["modules"].items() for path in mod["owned"]}
    folders = sorted(((m["folder"], n) for n, m in result["modules"].items() if m["folder"]), key=lambda x: -len(x[0]))

    def of(path: str) -> str:
        return owner.get(path) or next((n for f, n in folders if path.startswith(f + "/")), "(gone)")
    return of, result["modules"]


def pct(values: list[float], q: int) -> float:
    if len(values) < 2:
        return float(values[0]) if values else 0.0
    return round(statistics.quantiles(values, n=100)[q - 1], 1)


def ratio(part: float, whole: float) -> float:
    return round(part / whole, 3) if whole else 0.0


def weighted(rows: list[dict], key: str = "score") -> float:
    total = sum(r["lines"] for r in rows)
    return round(sum(r[key] * r["lines"] for r in rows) / total, 2) if total else 0.0


def file_rows(files: list[dict], commits: list[dict], module) -> list[dict]:
    stats = defaultdict(lambda: {"commits": 0, "fixes": 0, "cross": 0})
    for c in commits:
        mods = {module(p) for p in c["paths"]}
        for path in c["paths"]:
            s = stats[path]
            s["commits"] += 1
            s["fixes"] += c["fix"]
            s["cross"] += len(mods) > 1 and len(c["paths"]) <= BROAD
    rows = []
    for f in files:
        s = stats[f["path"]]
        rows.append({"path": f["path"], "module": module(f["path"]), "category": f["category"], "lines": f["lines"],
                     "commits": s["commits"], "fixes": s["fixes"], "crossModule": s["cross"],
                     "hotspot": round(s["fixes"] * f["lines"] / 1000, 2),
                     "score": file_score(f["lines"], s["commits"], s["fixes"], s["cross"])})
    return rows


def hotspots(rows: list[dict]) -> list[dict]:
    """Top 15 by fix commits x kLOC; at least three fixes, because one fix on a giant file is noise."""
    return sorted((r for r in rows if r["fixes"] >= 3), key=lambda r: (-r["hotspot"], r["path"]))[:15]


def measure(rev: str, days: int) -> dict:
    sha = metrics.resolve(rev)
    end = int(git("show", "-s", "--format=%ct", sha))
    files = [f for f in metrics.read_tree(sha) if f["category"] in SCORED]
    module, modules = modules_of(sha)
    commits = commits_in(sha, end - days * DAY, end)
    rows = file_rows(files, commits, module)
    landed = [line.split() for line in git("rev-list", "--first-parent", "--format=%H %ct", sha).splitlines()
              if not line.startswith("commit ")]
    landed = [h for h, t in landed if end - days * DAY < int(t) <= end]
    tree = git("diff-tree", "--stdin", "-r", "-m", "--first-parent", "--no-renames", "--name-only", "--always", "-z",
               data=("\n".join(landed) + "\n").encode()) if landed else ""
    spans, current, pending = [], None, set(landed)
    for token in tree.split("\0"):
        if token in pending:
            pending.discard(token)
            current = set()
            spans.append(current)
        elif token and current is not None:
            current.add(module(token))
    spans = [len(s) for s in spans if s]
    merges = [line.split() for line in git("rev-list", "--merges", "--parents", f"--max-age={end - days * DAY}",
                                           sha).splitlines()]
    conflicted = Counter()
    for _, first, second, *_ in merges:
        result = subprocess.run(["git", "-C", str(metrics.ROOT), "merge-tree", "--write-tree", "--name-only",
                                 "--no-messages", first, second], capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise metrics.MetricsError(f"merge-tree {first[:9]} {second[:9]}: {result.stderr.strip()}")
        if result.returncode == 1:
            conflicted.update(result.stdout.splitlines()[1:])
            conflicted["(merges)"] += 1
    goldens = [line.split()[2] for line in git("ls-tree", "-r", sha).splitlines() if ".golden." in line]
    pins = sum(len(HASH_PIN.findall(b)) for b in metrics.cat_blobs(goldens).values())
    hand = [r for r in rows if r["category"] in metrics.HAND_WRITTEN]
    lines = Counter()
    for r in rows:
        lines[r["category"]] += r["lines"]
    fixes = [c for c in commits if c["fix"]]
    top = {r["path"] for r in hotspots(rows)}
    return {
        "sha": sha, "end": end, "days": days, "rows": rows, "modules": modules, "landed": len(landed),
        "commits": commits, "conflicted": conflicted,
        "diagnostics": {
            "D1 size x churn: structural file score (line-weighted)": weighted(hand),
            "D1 hand-written lines": sum(r["lines"] for r in hand),
            "D2 rework: fix share of commits": ratio(len(fixes), len(commits)),
            "D2 rework: reverts": sum(1 for c in commits if c["subject"].lower().startswith("revert")),
            "D2 rework: fix commits touching a top-15 hotspot": ratio(sum(bool(top & set(c["paths"])) for c in fixes),
                                                                       len(fixes)),
            "D3 locality: modules per landed change p50 / p90": f"{pct(spans, 50)} / {pct(spans, 90)}",
            "D3 locality: landed changes touching >= 3 modules": ratio(sum(s >= 3 for s in spans), len(spans)),
            "D4 collisions: merges that re-resolve a conflict": ratio(conflicted["(merges)"], len(merges)),
            "D5 oracle cost: golden files / hash pins in them": f"{len(goldens)} / {pins}",
            "D5 oracle cost: commits touching a golden": ratio(sum(any(".golden." in p for p in c["paths"])
                                                                   for c in commits), len(commits)),
            "D5 oracle cost: test lines / production lines": ratio(lines["tests"], lines["production"]),
            "D6 navigability: modules with a purpose": f"{sum(1 for m in modules.values() if m['purpose'])}/{len(modules)}",
        },
    }


def github_outcomes(head: dict) -> list[str]:
    """O1 bug intake, O3 bug lead time and O4 red causes from GitHub issues (read-only `gh`)."""
    limit, issues, truncated = 1000, {}, False
    day = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d")  # noqa: E731
    for start in range(head["end"] - head["days"] * DAY, head["end"], 7 * DAY):
        raw = subprocess.run(["gh", "issue", "list", "--state", "all", "--limit", str(limit), "--search",
                              f"created:{day(start)}..{day(min(start + 6 * DAY, head['end']))}",
                              "--json", "number,title,labels,createdAt,closedAt,stateReason"],
                             capture_output=True, text=True, cwd=metrics.ROOT)
        if raw.returncode:
            raise OSError(f"gh issue list failed: {raw.stderr.strip()[:200]}")
        page = json.loads(raw.stdout)
        truncated |= len(page) >= limit
        issues.update((i["number"], i) for i in page)
    issues = list(issues.values())
    bugs = [i for i in issues if any(label["name"] == "kind:bug" for label in i["labels"])]

    def ts(value: str) -> float:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    hours = sorted((ts(b["closedAt"]) - ts(b["createdAt"])) / 3600 for b in bugs if b["stateReason"] == "COMPLETED")
    named = defaultdict(set)
    for c in head["commits"]:
        for n in ISSUE_REF.findall(c["subject"]):
            named[int(n)].update(c["paths"])
    reds = [i for i in issues if RED.search(i["title"])]
    causes = Counter("product" if any(metrics.classify(p, "100644", b"") == "production" for p in named[i["number"]])
                     else "no production change" if named[i["number"]] else "no commit" for i in reds)
    out = [f"  O1 kind:bug issues opened: {len(bugs)} ({ratio(len(bugs), head['landed'])} per landed change); "
           f"closed not planned {sum(b['stateReason'] == 'NOT_PLANNED' for b in bugs)}",
           f"  O3 bug opened -> closed completed, hours p50 / p90: {pct(hours, 50)} / {pct(hours, 90)} (n={len(hours)})",
           f"  O4 red or flake issues opened: {len(reds)}; a commit naming it changed production code "
           f"{ratio(causes['product'], len(reds))}, only non-production paths {ratio(causes['no production change'], len(reds))}, "
           f"no naming commit {ratio(causes['no commit'], len(reds))}"]
    return out + ([f"  warning: a weekly GitHub query hit the {limit}-issue limit; counts are truncated"] if truncated else [])


def rework_after_landing(head: dict) -> str:
    """O4: landed merges naming an issue that a later commit names again (a green that did not hold).
    Merges from the last three days are skipped: they have not had time to need rework."""
    names = defaultdict(list)
    for c in head["commits"]:
        for n in ISSUE_REF.findall(c["subject"]):
            names[n].append((c["time"], c["fix"]))
    landed = reworked = refixed = 0
    for line in git("log", "--first-parent", "--merges", f"--max-age={head['end'] - head['days'] * DAY}",
                    "--format=%ct %s", head["sha"]).splitlines():
        stamp, subject = line.split(" ", 1)
        if int(stamp) > head["end"] - 3 * DAY or not ISSUE_REF.search(subject):
            continue
        later = [x for n in ISSUE_REF.findall(subject) for x in names[n] if x[0] > int(stamp) + 600]
        landed += 1
        reworked += bool(later)
        refixed += any(fix for _, fix in later)
    return (f"  O4 landed merges naming an issue: {landed}; named again later {ratio(reworked, landed)}, "
            f"by a fix {ratio(refixed, landed)}")


def local_evidence(sha: str) -> list[str]:
    """O4 batch verdicts and feedback latency from this Mac's retained verify and batch reports."""
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    batches = []
    for report in glob.glob(str(common / "verify" / "batches" / "*" / "report.json")):
        name = Path(report).parent.name
        batches.append((int(name.rsplit("-", 1)[-1]) // 10**9, json.loads(Path(report).read_text()).get("verdict"),
                        name[:12]))
    batches.sort()
    heads = defaultdict(set)
    for _, verdict, head in batches:
        heads[head].add(verdict)
    green = [b for b in batches if b[1] == "green"]
    lanes = defaultdict(list)
    for tree in (line[9:] for line in git("worktree", "list", "--porcelain").splitlines() if line.startswith("worktree ")):
        for report in glob.glob(f"{tree}/test-results/verify/*.json"):
            try:
                steps = json.loads(Path(report).read_text()).get("steps", [])
            except (OSError, ValueError):
                continue
            for step in steps:
                if step.get("status") in ("ok", "failed") and (step.get("seconds") or 0) >= 1:
                    lanes[re.sub(r" \d+/\d+$", "", step["name"])].append(step["seconds"])
    now = int(git("show", "-s", "--format=%ct", sha))
    out = [f"  O4 batch runs {len(batches)}: " + ", ".join(f"{v} {n}" for v, n in sorted(Counter(b[1] for b in batches).items())),
           f"  O4 last green batch {green[-1][2]}, {(now - green[-1][0]) / DAY:.1f} days before this commit" if green
           else "  O4 no green batch retained",
           f"  O4 batch heads both green and red: {sum(1 for v in heads.values() if {'green', 'red'} <= v)} of {len(heads)}",
           "  D7 changed-module verify lane seconds p50 / p90 (n):"]
    out += [f"    {name}: {pct(v, 50):.0f} / {pct(v, 90):.0f} ({len(v)})" for name, v in sorted(lanes.items())
            if len(v) >= 3 and max(v) >= 10]
    return out


def deploy_outcomes(log: Path, head: dict) -> list[str]:
    """O3 landed -> Mac deploy lag and deploy failures from the Mac deploy log."""
    ready, started, failed = [], 0, 0
    start = head["end"] - head["days"] * DAY
    for raw in log.open(errors="replace"):
        try:
            event = json.loads(raw)
            when = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError):
            continue
        name = event.get("event")
        ready += [when] if name == "deploy.ready" else []
        if start < when <= head["end"]:
            started += name == "deploy.starting"
            failed += name in ("deploy.failure", "deploy.rolled-back")
    ready.sort()
    lag = []
    for line in git("rev-list", "--first-parent", f"--max-age={start}", "--format=%ct", head["sha"]).splitlines():
        if not line.startswith("commit "):
            later = [r for r in ready if r > int(line)]
            lag += [(later[0] - int(line)) / 3600] if later else []
    return [f"  O3 landed -> next Mac deploy, hours p50 / p90: {pct(lag, 50)} / {pct(lag, 90)} (n={len(lag)})",
            f"  O3 Mac deploys started {started}, failed or rolled back {failed}"]


def attention(sessions: Path, head: dict) -> str:
    """O2: Mohsin's typed Home messages per landed change and the share that chase status."""
    start, total, chase = head["end"] - head["days"] * DAY, 0, 0
    for path in sessions.glob("*.jsonl"):
        for raw in path.open(errors="replace"):
            if '"user"' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            message = entry.get("message") or {}
            if entry.get("type") != "message" or message.get("role") != "user" or not entry.get("timestamp"):
                continue
            content = message.get("content")
            text = content if isinstance(content, str) else " ".join(
                p.get("text", "") for p in content or [] if isinstance(p, dict))
            when = datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).timestamp()
            if start < when <= head["end"] and not text.lstrip().startswith(("[", "{")):
                total += 1
                chase += bool(CHASE.search(text[:400]))
    return (f"  O2 maintainer messages to Home: {total}; {ratio(total, head['landed'])} per landed change; "
            f"status chases {ratio(chase, total)}")


def spearman(a: list[float], b: list[float]) -> float:
    def rank(v):
        order, r, i = sorted(range(len(v)), key=lambda k: v[k]), [0.0] * len(v), 0
        while i < len(v):
            j = i
            while j + 1 < len(v) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2
            i = j + 1
        return r
    ra, rb = rank(a), rank(b)
    ma, mb = sum(ra) / len(ra), sum(rb) / len(rb)
    den = math.sqrt(sum((x - ma) ** 2 for x in ra) * sum((y - mb) ** 2 for y in rb))
    return sum((x - ma) * (y - mb) for x, y in zip(ra, rb)) / den if den else 0.0


def backtest(t0: str, t1: str) -> list[str]:
    """Do diagnostics measured at t0 predict rework in t0..t1? Later outcomes follow files through renames;
    the predictors' 30-day history before t0 does not, so a file renamed inside it starts fresh."""
    s0, s1 = metrics.resolve(t0), metrics.resolve(t1)
    end0, end1 = int(git("show", "-s", "--format=%ct", s0)), int(git("show", "-s", "--format=%ct", s1))
    files = {f["path"]: f for f in metrics.read_tree(s0) if f["category"] in ("production", "tests", "tooling")
             and f["lines"]}
    area = lambda p: "/".join(p.split("/")[:4 if p.startswith("packages/") else 2])  # noqa: E731
    rows = {r["path"]: r for r in file_rows(list(files.values()), commits_in(s0, end0 - DAYS * DAY, end0), area)}
    churned = Counter()
    for line in git("log", "--no-merges", "--no-renames", "--numstat", "--format=",
                    f"--since={end0 - DAYS * DAY}", s0).splitlines():
        added, deleted, path = (line.split("\t") + ["", "", ""])[:3]
        churned[path] += int(added) + int(deleted) if added.isdigit() and deleted.isdigit() else 0
    origin, later = {p: p for p in files}, defaultdict(Counter)
    for c in commits_in(s1, end0, end1, renames=True):
        touched = set()
        for change in c["changes"]:
            if change[0].startswith("R") and len(change) == 3 and change[1] in origin:
                origin[change[2]] = origin.pop(change[1])
                touched.add(origin[change[2]])
            elif change[-1] in origin:
                touched.add(origin[change[-1]])
        for p in touched:
            later[p]["commits"] += 1
            later[p]["fixes"] += c["fix"]
    paths = sorted(files)
    fixes = [later[p]["fixes"] for p in paths]
    active = [i for i, p in enumerate(paths) if later[p]["commits"] >= 3]
    predictors = {
        "size": [rows[p]["lines"] for p in paths],
        "churn (commits)": [rows[p]["commits"] for p in paths],
        "relative churn": [churned[p] / rows[p]["lines"] for p in paths],
        "prior fixes": [rows[p]["fixes"] for p in paths],
        "hotspot (fixes x kLOC)": [rows[p]["hotspot"] for p in paths],
        "cross-area co-change": [rows[p]["crossModule"] for p in paths],
        "file score (inverted)": [10 - rows[p]["score"] for p in paths],
    }
    out = [f"Backtest {s0[:9]} -> {s1[:9]}: {len(paths)} files, {sum(fixes)} later fix touches "
           "(rho = Spearman; capture = share of later fix touches in the predicted top 10%; random = 10%)"]
    for name, v in predictors.items():
        top = sorted(range(len(v)), key=lambda i: -v[i])[:len(v) // 10]
        share = [later[paths[i]]["fixes"] / later[paths[i]]["commits"] for i in active]
        out.append(f"  {name}: rho fixes {spearman(v, fixes):.2f}; capture {ratio(sum(fixes[i] for i in top), sum(fixes)):.0%}; "
                   f"rho fix share {spearman([v[i] for i in active], share):.2f}")
    return out


def report(head: dict, base: dict | None) -> list[str]:
    lines = [f"Health {head['sha'][:9]} ({head['days']}d window; docs/HEALTH.md). Signals, never gates.", "",
             "| Diagnostic (Git) | Baseline | Now |" if base else "| Diagnostic (Git) | Now |",
             "|---|---:|---:|" if base else "|---|---:|"]
    for key, value in head["diagnostics"].items():
        lines.append(f"| {key} | {base['diagnostics'][key]} | {value} |" if base else f"| {key} | {value} |")
    lines += ["", "Top 15 hotspots (fix commits x kLOC):"]
    lines += [f"  {r['hotspot']:>6} {r['path']} ({r['lines']} lines, {r['fixes']}/{r['commits']} fix, "
              f"cross-module {r['crossModule']})" for r in hotspots(head["rows"])]
    shared = sorted(((n, p) for p, n in head["conflicted"].items() if p != "(merges)"), reverse=True)[:5]
    lines += ["", "Collision-prone files (re-resolved in conflicted merges): "
              + (", ".join(f"{p} ({n})" for n, p in shared) or "none")]
    return lines


def write_csvs(head: dict, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    tables = {"files.csv": head["rows"]}
    for name, key in (("folders.csv", lambda r: "/".join(r["path"].split("/")[:2])), ("modules.csv", lambda r: r["module"])):
        groups = defaultdict(list)
        for r in head["rows"]:
            groups[key(r)].append(r)
        tables[name] = [{"group": g, "files": len(rs), "lines": sum(r["lines"] for r in rs), "score": weighted(rs),
                         "fixes": sum(r["fixes"] for r in rs), "hotspot": round(sum(r["hotspot"] for r in rs), 1)}
                        for g, rs in sorted(groups.items())]
    for name, rows in tables.items():
        if not rows:
            continue
        with (out / name).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/tron health", description=__doc__.splitlines()[0])
    parser.add_argument("rev", nargs="?", default="HEAD")
    parser.add_argument("--baseline", default=BASELINE, help=f"commit to diff against (default {BASELINE})")
    parser.add_argument("--days", type=int, default=DAYS, help="history window before each commit")
    parser.add_argument("--csv", metavar="DIR", type=Path, help="write files.csv, folders.csv and modules.csv")
    parser.add_argument("--github", action="store_true", help="O1/O3 bug intake and lead time via gh")
    parser.add_argument("--evidence", action="store_true", help="O4/D7 from this Mac's verify and batch reports")
    parser.add_argument("--deploy-log", metavar="JSONL", type=Path, help="O3 from the Mac deploy log")
    parser.add_argument("--home-sessions", metavar="DIR", type=Path, help="O2 from the Home session directory")
    parser.add_argument("--backtest", metavar="T0", help="validate diagnostics at T0 against rework up to rev")
    args = parser.parse_args(argv)
    try:
        head = measure(args.rev, args.days)
        base = None if metrics.resolve(args.baseline) == head["sha"] else measure(args.baseline, args.days)
        lines = report(head, base)
        lines += ["", "Outcomes:", rework_after_landing(head)]
        lines += github_outcomes(head) if args.github else []
        lines += deploy_outcomes(args.deploy_log, head) if args.deploy_log else []
        lines += [attention(args.home_sessions, head)] if args.home_sessions else []
        lines += local_evidence(head["sha"]) if args.evidence else []
        lines += [""] + backtest(args.backtest, head["sha"]) if args.backtest else []
    except (metrics.MetricsError, ownership.GitError, OSError, ValueError) as error:
        print(f"health: {error}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    if args.csv:
        write_csvs(head, args.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
