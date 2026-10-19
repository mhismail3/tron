#!/usr/bin/env python3
"""Read-only, deterministic restructure metrics (docs/restructure/plan.md §3).

Every number is computed from Git objects of one commit, never from the working
tree or the wall clock, so the same commit always yields byte-identical JSON.
Definitions, classification rules and unavailable metrics: tools/metrics/README.md.
The tool reports; it never gates (exit status reflects only usage or Git errors).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "tron-metrics/1"
SIZE_THRESHOLD = 500
HOTSPOT_WINDOW_DAYS = 30
HOTSPOT_TOP = 10
BINARY_PROBE_BYTES = 8000

HAND_WRITTEN = ("production", "tests", "tooling", "docs")
SEPARATE = ("fixtures",)
EXCLUDED = ("data", "lockfile", "thirdParty", "binary")
CATEGORIES = HAND_WRITTEN + SEPARATE + EXCLUDED

CODE_SUFFIXES = {
    ".ts", ".mts", ".cts", ".tsx", ".js", ".mjs", ".cjs", ".jsx",
    ".swift", ".py", ".sh", ".bash", ".c", ".h", ".m", ".mm", ".css", ".html",
}
SCRIPT_SUFFIXES = {".py", ".sh", ".bash"}
DOC_SUFFIXES = {".md", ".mdx"}
LOCKFILES = {
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
    "Package.resolved",
}
TEST_DIRS = {
    "test-support", "test-fixtures", "tests", "Tests", "fixtures", "Fixtures",
    "E2ETests", "ProfilingTests",
}
TOOLING_ROOTS = {"scripts", "tools", ".agents", ".github", ".codex", ".pi"}
# Shipped sources that live beside tooling: the Mac bundle compiles this launcher.
PRODUCTION_PATHS = {"packages/mac-app/scripts/tron-gateway-launcher.c"}
LEGAL = re.compile(r"(?i)(^|[-_.])(license|notice|copying)$")
TEST_NAME = re.compile(r"\.test\.[A-Za-z0-9]+$")
HOSTED_FIXTURE = re.compile(r"^(Hosted\w*(Fixture|Probe)\w*|\w+HostedProbe)\.swift$")

UNAVAILABLE = {
    "M1.lockCoverage": (
        "No capability catalog (plan §6.3) or behavior locks exist yet.",
        "0.4 manifests (catalog); 0.8 Gateway locks #1355; 0.9 iOS locks #1356",
    ),
    "M1.lockDeterminism": (
        "No behavior locks exist yet to rerun.",
        "0.8 Gateway locks #1355; 0.9 iOS locks #1356",
    ),
    "M1.lockSensitivity": (
        "No locks or evaluated mutation tool yet; sampled at milestones.",
        "0.10 persisted, wire and sensitivity",
    ),
    "M2.layerViolations": (
        "Needs manifest layers and a resolved import/reference graph; text grep "
        "misreads type-only, dynamic, re-exported and path-mapped edges.",
        "0.4 manifests; 0.6 layer checker #1354",
    ),
    "M2.directoryCycles": (
        "Needs the resolved import/reference graph, not grep-inferred edges.",
        "0.6 layer checker #1354",
    ),
    "M2.fileSizeExceptions": (
        "Exceptions are recorded in module manifests, which do not exist yet.",
        "0.4 manifests; 0.7 budget checker #1354",
    ),
    "M2.registrationFootprint": (
        "Needs module descriptors and composition roots.",
        "Phase 2 K-0 and pilot module #1348",
    ),
    "M2.navigationProbe": (
        "A fresh-agent probe run at milestones, not a repository computation.",
        "Milestone steward (plan §14.8)",
    ),
    "M4.sliceVerifyTime": (
        "`scripts/tron verify --changed` does not exist yet.",
        "0.11 scripts/tron verify #1354",
    ),
    "ownership.ledger": (
        "Ownership and module checklists do not exist yet.",
        "0.4 manifests; 0.5 ledger #1357",
    ),
}


class MetricsError(Exception):
    pass


def git(*args: str, data: bytes | None = None) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        raise MetricsError(completed.stderr.decode(errors="replace").strip() or f"git {args[0]} failed")
    return completed.stdout


def resolve(rev: str) -> str:
    try:
        return git("rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}").decode().strip()
    except MetricsError:
        raise MetricsError(f"unknown revision: {rev}") from None


def count_lines(content: bytes) -> int:
    if not content:
        return 0
    return content.count(b"\n") + (0 if content.endswith(b"\n") else 1)


def package_of(path: str) -> str:
    parts = path.split("/")
    if len(parts) == 1:
        return "(root)"
    if parts[0] == "packages":
        return parts[1]
    return parts[0]


def classify(path: str, mode: str, content: bytes) -> str:
    pure = PurePosixPath(path)
    name, suffix, dirs = pure.name, pure.suffix, pure.parts[:-1]
    if mode == "160000":
        return "thirdParty"
    if mode == "120000":
        return "data"
    if b"\0" in content[:BINARY_PROBE_BYTES]:
        return "binary"
    if name in LOCKFILES or name.endswith("-package-lock.json"):
        return "lockfile"
    if "third_party" in dirs or (suffix in {"", ".txt", ".md"} and LEGAL.search(pure.stem)):
        return "thirdParty"
    if suffix in DOC_SUFFIXES:
        return "docs"
    is_code = suffix in CODE_SUFFIXES or (suffix == "" and content.startswith(b"#!"))
    if is_code:
        if (
            TEST_NAME.search(name)
            or name.startswith(("test-", "test_"))
            or name.startswith("vitest") and ".config." in name
            or HOSTED_FIXTURE.match(name)
            or any(d in TEST_DIRS or d.endswith("UITests") for d in dirs)
        ):
            return "tests"
        if path in PRODUCTION_PATHS:
            return "production"
        if (
            pure.parts[0] in TOOLING_ROOTS
            or (len(dirs) >= 3 and dirs[0] == "packages" and dirs[2] == "scripts")
            or suffix in SCRIPT_SUFFIXES
            or suffix == ""
        ):
            return "tooling"
        return "production"
    if any("fixture" in d.lower() or d == "test-support" for d in dirs) or ".golden." in name:
        return "fixtures"
    return "data"


def read_tree(sha: str) -> list[dict]:
    entries = []
    for record in git("ls-tree", "-r", "-z", "--full-tree", sha).split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        entries.append({"path": path.decode(), "mode": mode, "kind": kind, "oid": oid})
    blobs = [e for e in entries if e["kind"] == "blob"]
    contents = cat_blobs([e["oid"] for e in blobs])
    files = []
    for entry in entries:
        content = contents.get(entry["oid"], b"") if entry["kind"] == "blob" else b""
        category = classify(entry["path"], entry["mode"], content)
        files.append({
            "path": entry["path"],
            "category": category,
            "package": package_of(entry["path"]),
            "bytes": len(content),
            "lines": 0 if category == "binary" else count_lines(content),
        })
    files.sort(key=lambda f: f["path"])
    return files


def cat_blobs(oids: list[str]) -> dict[str, bytes]:
    unique = sorted(set(oids))
    if not unique:
        return {}
    output = git("cat-file", "--batch", data=("\n".join(unique) + "\n").encode())
    contents, offset = {}, 0
    for oid in unique:
        header_end = output.index(b"\n", offset)
        header = output[offset:header_end].decode().split()
        if len(header) != 3 or header[0] != oid:
            raise MetricsError(f"unexpected cat-file header for {oid}: {header}")
        size = int(header[2])
        start = header_end + 1
        contents[oid] = output[start:start + size]
        offset = start + size + 1
    return contents


def iso(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hotspot(sha: str, end: int) -> dict:
    start = end - HOTSPOT_WINDOW_DAYS * 86400
    window = []
    for line in git("rev-list", "--no-merges", "--format=%H %ct", sha).decode().splitlines():
        if line.startswith("commit "):
            continue
        commit, stamp = line.split()
        if start < int(stamp) <= end:
            window.append(commit)
    touched: dict[str, set[str]] = {}
    if window:
        # --always prints every commit id, in input order, before its paths.
        tokens = git(
            "diff-tree", "--stdin", "-r", "--root", "--always", "--no-renames", "--name-only", "-z",
            data=("\n".join(window) + "\n").encode(),
        ).decode().split("\0")
        pending, commit = iter(window), None
        upcoming = next(pending)
        for token in tokens:
            if token == upcoming:
                commit, upcoming = token, next(pending, None)
            elif token:
                touched.setdefault(token, set()).add(commit)
    ranked = sorted(touched.items(), key=lambda item: (-len(item[1]), item[0]))[:HOTSPOT_TOP]
    hit = set().union(*(commits for _, commits in ranked)) if ranked else set()
    return {
        "status": "observed",
        "windowDays": HOTSPOT_WINDOW_DAYS,
        "windowStart": iso(start),
        "windowEnd": iso(end),
        "commits": len(window),
        "touchingTop": len(hit),
        "share": round(len(hit) / len(window), 4) if window else 0.0,
        "top": [{"path": path, "commits": len(commits)} for path, commits in ranked],
    }


def tally(files: list[dict], categories: tuple[str, ...]) -> dict:
    result = {c: {"files": 0, "lines": 0, "bytes": 0} for c in categories}
    for f in files:
        if f["category"] in result:
            bucket = result[f["category"]]
            bucket["files"] += 1
            bucket["lines"] += f["lines"]
            bucket["bytes"] += f["bytes"]
    return result


def measure(sha: str) -> dict:
    files = read_tree(sha)
    committed = int(git("show", "-s", "--format=%ct", sha).decode().strip())
    hand = [f for f in files if f["category"] in HAND_WRITTEN]
    by_package: dict[str, dict[str, int]] = {}
    for f in hand:
        row = by_package.setdefault(f["package"], {c: 0 for c in HAND_WRITTEN})
        row[f["category"]] += f["lines"]
    large = sorted(
        (f for f in hand if f["lines"] > SIZE_THRESHOLD),
        key=lambda f: (-f["lines"], f["path"]),
    )
    metrics = {
        "M2.fileSize": {
            "status": "observed",
            "threshold": SIZE_THRESHOLD,
            "count": len(large),
            "byCategory": {c: sum(1 for f in large if f["category"] == c) for c in HAND_WRITTEN},
            "files": [{"path": f["path"], "category": f["category"], "lines": f["lines"]} for f in large],
        },
        "M2.hotspotShare": hotspot(sha, committed),
        "M3.size": {
            "status": "observed",
            "handWrittenLines": sum(f["lines"] for f in hand),
            "handWrittenFiles": len(hand),
            "byCategory": tally(files, CATEGORIES),
            "handWrittenByPackage": dict(sorted(by_package.items())),
        },
    }
    for key, (reason, owner) in UNAVAILABLE.items():
        metrics[key] = {"status": "unavailable", "reason": reason, "owner": owner}
    return {
        "schema": SCHEMA,
        "definitions": "tools/metrics/README.md",
        "commit": sha,
        "committedAt": iso(committed),
        "metrics": dict(sorted(metrics.items())),
        "files": files,
    }


def write(result: dict) -> Path:
    out_dir = ROOT / "test-results" / "metrics"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{result['commit']}.json"
    temp = path.with_suffix(".json.tmp")
    temp.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    temp.replace(path)
    return path


def renames(base: str, head: str) -> list[tuple[str, str | None, str | None]]:
    """(status, old, new) per changed path with renames paired by Git's -M."""
    raw = git(
        "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "-M", "-l100000",
        base, head,
    ).decode().split("\0")
    changes, index = [], 0
    while index < len(raw) and raw[index]:
        status = raw[index][0]
        if status == "R":
            changes.append(("R", raw[index + 1], raw[index + 2]))
            index += 3
        else:
            path = raw[index + 1]
            changes.append((status, None if status == "A" else path, None if status == "D" else path))
            index += 2
    return changes


def fmt(value: int) -> str:
    return f"{value:,}"


def signed(value: int) -> str:
    return f"{value:+,}" if value else "0"


def pct(hot: dict) -> str:
    return f"{hot['share'] * 100:.1f}% ({hot['touchingTop']}/{hot['commits']})"


def compare(base: dict, head: dict) -> str:
    bs, hs = base["metrics"]["M3.size"], head["metrics"]["M3.size"]
    bf, hf = base["metrics"]["M2.fileSize"], head["metrics"]["M2.fileSize"]
    bh, hh = base["metrics"]["M2.hotspotShare"], head["metrics"]["M2.hotspotShare"]
    lines = [
        f"Metrics Δ {base['commit'][:9]} → {head['commit'][:9]} ({SCHEMA}; tools/metrics/README.md)",
        "",
        "| Metric | Base | Head | Δ |",
        "|---|---:|---:|---:|",
        f"| Hand-written lines | {fmt(bs['handWrittenLines'])} | {fmt(hs['handWrittenLines'])} | "
        f"{signed(hs['handWrittenLines'] - bs['handWrittenLines'])} |",
    ]
    for c in HAND_WRITTEN:
        b, h = bs["byCategory"][c]["lines"], hs["byCategory"][c]["lines"]
        lines.append(f"| · {c} | {fmt(b)} | {fmt(h)} | {signed(h - b)} |")
    b, h = bs["byCategory"]["fixtures"]["lines"], hs["byCategory"]["fixtures"]["lines"]
    lines.append(f"| Fixture data lines (separate) | {fmt(b)} | {fmt(h)} | {signed(h - b)} |")
    lines.append(f"| Hand-written files > {SIZE_THRESHOLD} lines | {bf['count']} | {hf['count']} | "
                 f"{signed(hf['count'] - bf['count'])} |")
    delta_pp = (hh["share"] - bh["share"]) * 100
    lines.append(f"| Hotspot share ({HOTSPOT_WINDOW_DAYS}d, top {HOTSPOT_TOP}) | {pct(bh)} | {pct(hh)} | "
                 f"{delta_pp:+.1f} pp |")
    excluded = []
    for c in ("data", "lockfile", "thirdParty"):
        excluded.append(f"{c} lines {fmt(bs['byCategory'][c]['lines'])} → {fmt(hs['byCategory'][c]['lines'])}")
    excluded.append(f"binary bytes {fmt(bs['byCategory']['binary']['bytes'])} → "
                    f"{fmt(hs['byCategory']['binary']['bytes'])}")
    lines += ["", "Excluded (not hand-written): " + "; ".join(excluded) + "."]
    unavailable = [k for k, v in head["metrics"].items() if v["status"] == "unavailable"]
    lines.append("Unavailable (not measured; owners in JSON): " + ", ".join(unavailable) + ".")

    base_files = {f["path"]: f for f in base["files"]}
    head_files = {f["path"]: f for f in head["files"]}

    def hand(f: dict | None) -> int:
        return f["lines"] if f and f["category"] in HAND_WRITTEN else 0

    kinds = ("added", "deleted", "renamed", "modified")
    changes = {k: [0, 0] for k in kinds}
    rename_map, reclassified = {}, []
    for status, old, new in renames(base["commit"], head["commit"]):
        before, after = base_files.get(old) if old else None, head_files.get(new) if new else None
        kind = {"A": "added", "D": "deleted", "R": "renamed"}.get(status, "modified")
        changes[kind][0] += 1
        changes[kind][1] += hand(after) - hand(before)
        if status == "R":
            rename_map[old] = new
        if before and after and before["category"] != after["category"]:
            label = old if old == new else f"{old} → {new}"
            reclassified.append(f"{label} ({before['category']} → {after['category']})")
    lines += ["", "| Change (git diff -M; renames paired) | Files | Hand-written lines |", "|---|---:|---:|"]
    for kind in kinds:
        lines.append(f"| {kind} | {changes[kind][0]} | {signed(changes[kind][1])} |")
    lines.append(f"| reclassified | {len(reclassified)} | (included above) |")
    for item in reclassified:
        lines.append(f"- reclassified: {item}")

    base_large = {f["path"]: f for f in bf["files"]}
    head_large = {f["path"]: f for f in hf["files"]}
    reached = set()
    for path, f in base_large.items():
        mapped = rename_map.get(path, path)
        if mapped in head_large:
            reached.add(mapped)
            if mapped != path:
                lines.append(f"- >{SIZE_THRESHOLD} renamed: {path} → {mapped} "
                             f"({f['lines']} → {head_large[mapped]['lines']})")
        else:
            gone = "deleted" if mapped not in head_files else f"now {head_files[mapped]['lines']}"
            where = path if mapped == path else f"{path} → {mapped}"
            lines.append(f"- >{SIZE_THRESHOLD} left: {where} ({f['lines']}; {gone})")
    for path, f in head_large.items():
        if path not in reached:
            lines.append(f"- >{SIZE_THRESHOLD} entered: {path} ({f['lines']})")

    d = {c: hs["byCategory"][c]["lines"] - bs["byCategory"][c]["lines"] for c in HAND_WRITTEN}
    lines += [
        "",
        f"Metrics Δ: LOC prod/test/tool/docs {signed(d['production'])}/{signed(d['tests'])}/"
        f"{signed(d['tooling'])}/{signed(d['docs'])}; files>{SIZE_THRESHOLD} "
        f"{signed(hf['count'] - bf['count'])}; violations unavailable (0.6); "
        f"hotspot {bh['share'] * 100:.1f}%→{hh['share'] * 100:.1f}%.",
    ]
    return "\n".join(lines)


def summary(result: dict) -> str:
    size = result["metrics"]["M3.size"]
    large = result["metrics"]["M2.fileSize"]
    hot = result["metrics"]["M2.hotspotShare"]
    cats = size["byCategory"]
    parts = ", ".join(f"{c} {fmt(cats[c]['lines'])}" for c in HAND_WRITTEN)
    return "\n".join([
        f"Metrics {result['commit'][:9]} ({SCHEMA}; tools/metrics/README.md)",
        f"Hand-written lines {fmt(size['handWrittenLines'])} in {size['handWrittenFiles']} files: {parts}",
        f"Fixture data lines {fmt(cats['fixtures']['lines'])} (separate)",
        f"Hand-written files > {SIZE_THRESHOLD} lines: {large['count']} "
        + "(" + ", ".join(f"{c} {n}" for c, n in large["byCategory"].items()) + ")",
        f"Hotspot share ({HOTSPOT_WINDOW_DAYS}d to {hot['windowEnd']}, top {HOTSPOT_TOP}): {pct(hot)}",
        "Unavailable: " + ", ".join(k for k, v in result["metrics"].items() if v["status"] == "unavailable"),
    ])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="scripts/tron metrics",
        description="Measure one commit from Git objects; write test-results/metrics/<sha>.json. Never a gate.",
    )
    parser.add_argument("rev", nargs="?", default="HEAD", help="commit to measure (head with --compare)")
    parser.add_argument("--compare", metavar="BASE", help="print the delta table from BASE to REV")
    args = parser.parse_args(argv)
    try:
        head_sha = resolve(args.rev)
        base_sha = resolve(args.compare) if args.compare else None
        head = measure(head_sha)
        base = measure(base_sha) if base_sha else None
    except MetricsError as error:
        print(f"metrics: {error}", file=sys.stderr)
        return 2
    paths = [write(head)] + ([write(base)] if base else [])
    print(compare(base, head) if base else summary(head), flush=True)
    for path in paths:
        print(f"wrote {path.relative_to(ROOT)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
