#!/usr/bin/env python3
"""Report, comparison, and status owner for scripts/tron-profile.

Every profiler lane (iOS scenarios, Gateway wire traffic) hands this module raw
per-iteration samples. It owns the one report schema, the environment and
source identity stamped into each report, the noise bound, and the verdict that
decides whether a change regressed a metric. Keeping that policy here means an
agent comparing two runs never reimplements statistics or reads a metric
without its unit, direction, spread, and host conditions.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tempfile
from typing import Any

SCHEMA = "tron.profile-report.v1"
SAMPLES_SCHEMA = "tron.profile-samples.v1"
TOOLS = ("ios", "gateway")
DIRECTIONS = ("lower", "higher")
# A delta must exceed both a relative floor and three robust standard
# deviations before it is a verdict; smaller movement is reported as noise.
DEFAULT_FLOOR = 0.03
SPREAD_MULTIPLIER = 3.0
MAD_TO_SIGMA = 1.4826
MINIMUM_SAMPLES = 3

EXIT_OK = 0
EXIT_INVALID = 2
EXIT_REGRESSION = 3

METRIC_ID = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,159}$")


class ReportError(Exception):
    pass


def profile_root() -> Path:
    configured = os.environ.get("TRON_PROFILE_RESULTS_DIR")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / "Library/Developer/Tron/profiles"


def summarize(values: list[float]) -> dict[str, Any]:
    if not values:
        raise ReportError("a metric needs at least one sample")
    for value in values:
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ReportError(f"non-finite or non-numeric sample: {value!r}")
    ordered = sorted(float(value) for value in values)
    median = statistics.median(ordered)
    mad = statistics.median(abs(value - median) for value in ordered)
    return {
        "samples": [float(value) for value in values],
        "count": len(ordered),
        "median": median,
        "mad": mad,
        "min": ordered[0],
        "max": ordered[-1],
    }


def _run(command: list[str], cwd: Path | None = None) -> str | None:
    try:
        return subprocess.run(
            command, cwd=cwd, check=True, capture_output=True, text=True, timeout=20
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


def source_identity(worktree: Path) -> dict[str, Any]:
    revision = _run(["git", "rev-parse", "HEAD"], worktree)
    branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], worktree)
    status = _run(["git", "status", "--porcelain", "--untracked-files=no"], worktree)
    changed = [line for line in (status or "").splitlines() if line.strip()]
    return {
        "worktree": str(worktree),
        "revision": revision,
        "branch": branch,
        "dirty": bool(changed),
        "changed_tracked_files": len(changed),
    }


def _booted_simulators() -> int | None:
    output = _run(["xcrun", "simctl", "list", "devices", "booted", "--json"])
    if output is None:
        return None
    try:
        devices = json.loads(output).get("devices", {})
    except json.JSONDecodeError:
        return None
    return sum(len(values) for values in devices.values())


def environment() -> dict[str, Any]:
    load = os.getloadavg()
    cpu_count = os.cpu_count() or 0
    battery = _run(["pmset", "-g", "batt"]) or ""
    thermal = _run(["pmset", "-g", "therm"]) or ""
    speed = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", thermal)
    power_settings = _run(["pmset", "-g"]) or ""
    low_power = re.search(r"lowpowermode\s+(\d)", power_settings)
    value: dict[str, Any] = {
        "host_arch": platform.machine(),
        "macos": platform.mac_ver()[0] or None,
        "cpu_count": cpu_count,
        "load_average": [round(item, 2) for item in load],
        "booted_simulators": _booted_simulators(),
        "power_source": (
            "ac" if "AC Power" in battery else "battery" if "Battery Power" in battery else None
        ),
        "cpu_speed_limit": int(speed.group(1)) if speed else None,
        "low_power_mode": (low_power.group(1) == "1") if low_power else None,
    }
    warnings = []
    if cpu_count and load[0] > cpu_count * 0.5:
        warnings.append(f"host busy: 1-minute load {load[0]:.1f} on {cpu_count} CPUs")
    if value["power_source"] == "battery":
        warnings.append("host on battery power")
    if value["cpu_speed_limit"] is not None and value["cpu_speed_limit"] < 100:
        warnings.append(f"host CPU speed limited to {value['cpu_speed_limit']}%")
    if value["low_power_mode"]:
        warnings.append("host Low Power Mode enabled")
    value["warnings"] = warnings
    return value


def validate_samples(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict) or document.get("schema") != SAMPLES_SCHEMA:
        raise ReportError(f"samples must use schema {SAMPLES_SCHEMA}")
    metrics = document.get("metrics")
    if not isinstance(metrics, dict) or not metrics:
        raise ReportError("samples contain no metrics")
    for metric_id, metric in metrics.items():
        if not METRIC_ID.match(metric_id):
            raise ReportError(f"invalid metric id: {metric_id!r}")
        if not isinstance(metric, dict):
            raise ReportError(f"metric {metric_id} must be an object")
        if not isinstance(metric.get("unit"), str) or not metric["unit"]:
            raise ReportError(f"metric {metric_id} needs a unit")
        if metric.get("better") not in DIRECTIONS:
            raise ReportError(f"metric {metric_id} needs better=lower|higher")
        if not isinstance(metric.get("values"), list) or not metric["values"]:
            raise ReportError(f"metric {metric_id} has no samples")
    return document


def build_report(
    tool: str,
    scenario: str,
    samples: dict[str, Any],
    worktree: Path,
    run_id: str,
    artifacts: dict[str, str],
    context: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if tool not in TOOLS:
        raise ReportError(f"unknown tool: {tool}")
    if not re.match(r"^[a-z0-9][a-z0-9-]{0,63}$", scenario):
        raise ReportError(f"invalid scenario name: {scenario!r}")
    validate_samples(samples)
    metrics = {}
    for metric_id, metric in sorted(samples["metrics"].items()):
        summary = summarize(metric["values"])
        metrics[metric_id] = {
            "unit": metric["unit"],
            "better": metric["better"],
            **({"description": metric["description"]} if isinstance(metric.get("description"), str) else {}),
            **summary,
        }
    counts = {metric["count"] for metric in metrics.values()}
    host = environment()
    quality = list(host["warnings"])
    if min(counts) < MINIMUM_SAMPLES:
        quality.append(f"fewer than {MINIMUM_SAMPLES} samples for some metrics; comparisons use the relative floor only")
    source = source_identity(worktree)
    if source["dirty"]:
        quality.append("measured a worktree with uncommitted tracked changes")
    return {
        "schema": SCHEMA,
        "tool": tool,
        "scenario": scenario,
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": source,
        "environment": host,
        "context": context or samples.get("context") or {},
        "measurement_warnings": quality,
        "metrics": metrics,
        "artifacts": artifacts,
    }


def _format(value: float, unit: str) -> str:
    magnitude = abs(value)
    if unit in ("B", "bytes"):
        for suffix, scale in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
            if magnitude >= scale:
                return f"{value / scale:.2f} {suffix}"
        return f"{value:.0f} B"
    if unit == "ns":
        if magnitude >= 1e9:
            return f"{value / 1e9:.3f} s"
        if magnitude >= 1e6:
            return f"{value / 1e6:.2f} ms"
        return f"{value / 1e3:.1f} µs"
    if unit == "nJ":
        if magnitude >= 1e9:
            return f"{value / 1e9:.3f} J"
        return f"{value / 1e6:.2f} mJ"
    if magnitude >= 1e9:
        return f"{value / 1e9:.3f}G {unit}"
    if magnitude >= 1e6:
        return f"{value / 1e6:.3f}M {unit}"
    if float(value).is_integer():
        return f"{value:.0f} {unit}"
    return f"{value:.3f} {unit}"


def markdown_summary(report: dict[str, Any]) -> str:
    source = report["source"]
    lines = [
        f"# {report['tool']} profile: {report['scenario']}",
        "",
        f"- Run: `{report['run_id']}` at {report['created_at']}",
        f"- Source: {source.get('branch')} @ {str(source.get('revision'))[:12]}"
        + (" (dirty)" if source.get("dirty") else ""),
        f"- Host load: {report['environment']['load_average']}, booted simulators: "
        f"{report['environment']['booted_simulators']}",
    ]
    for warning in report["measurement_warnings"]:
        lines.append(f"- Warning: {warning}")
    lines += ["", "| Metric | Median | Spread (MAD) | Samples | Better |", "| --- | --- | --- | --- | --- |"]
    for metric_id, metric in report["metrics"].items():
        lines.append(
            f"| {metric_id} | {_format(metric['median'], metric['unit'])} | "
            f"{_format(metric['mad'], metric['unit'])} | {metric['count']} | {metric['better']} |"
        )
    return "\n".join(lines) + "\n"


def write_report(report: dict[str, Any], run_dir: Path) -> Path:
    run_dir.mkdir(parents=True, exist_ok=True)
    destination = run_dir / "report.json"
    # Write-then-rename so a reader never sees a truncated report.
    with tempfile.NamedTemporaryFile("w", dir=run_dir, delete=False, suffix=".tmp") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(destination)
    (run_dir / "summary.md").write_text(markdown_summary(report))
    latest = run_dir.parent / "latest"
    try:
        if latest.is_symlink() or not latest.exists():
            if latest.is_symlink():
                latest.unlink()
            latest.symlink_to(run_dir.name)
    except OSError:
        pass
    return destination


def load_report(path: Path) -> dict[str, Any]:
    if path.is_dir():
        path = path / "report.json"
    try:
        report = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReportError(f"cannot read report {path}: {error}") from error
    if not isinstance(report, dict) or report.get("schema") != SCHEMA:
        raise ReportError(f"{path} is not a {SCHEMA} report")
    if not isinstance(report.get("metrics"), dict):
        raise ReportError(f"{path} has no metrics")
    return report


def compare_metric(base: dict[str, Any], candidate: dict[str, Any], floor: float) -> dict[str, Any]:
    if base["unit"] != candidate["unit"] or base["better"] != candidate["better"]:
        return {"verdict": "incomparable", "reason": "unit or direction changed"}
    delta = candidate["median"] - base["median"]
    spread = MAD_TO_SIGMA * max(base["mad"], candidate["mad"])
    enough = min(base["count"], candidate["count"]) >= MINIMUM_SAMPLES
    noise = max(
        SPREAD_MULTIPLIER * spread if enough else 0.0,
        floor * abs(base["median"]),
    )
    relative = (delta / abs(base["median"])) if base["median"] else (math.inf if delta else 0.0)
    worse = delta > 0 if base["better"] == "lower" else delta < 0
    if abs(delta) <= noise:
        verdict = "unchanged"
    else:
        verdict = "regression" if worse else "improvement"
    return {
        "verdict": verdict,
        "base_median": base["median"],
        "candidate_median": candidate["median"],
        "delta": delta,
        "relative": relative,
        "noise_bound": noise,
        "samples": [base["count"], candidate["count"]],
    }


def compare(base: dict[str, Any], candidate: dict[str, Any], floor: float, allow_mismatch: bool) -> dict[str, Any]:
    mismatch = [
        key for key in ("tool", "scenario") if base.get(key) != candidate.get(key)
    ]
    if mismatch and not allow_mismatch:
        raise ReportError(f"reports differ in {', '.join(mismatch)}; pass --allow-mismatch to compare anyway")
    results = {}
    for metric_id in sorted(set(base["metrics"]) | set(candidate["metrics"])):
        left, right = base["metrics"].get(metric_id), candidate["metrics"].get(metric_id)
        if left is None:
            results[metric_id] = {"verdict": "missing-in-base"}
        elif right is None:
            results[metric_id] = {"verdict": "missing-in-candidate"}
        else:
            results[metric_id] = compare_metric(left, right, floor)
    verdicts = [result["verdict"] for result in results.values()]
    return {
        "schema": "tron.profile-comparison.v1",
        "base": {"run_id": base.get("run_id"), "source": base.get("source")},
        "candidate": {"run_id": candidate.get("run_id"), "source": candidate.get("source")},
        "floor": floor,
        "warnings": sorted(set(base.get("measurement_warnings", []) + candidate.get("measurement_warnings", []))),
        "metrics": results,
        "regressions": verdicts.count("regression"),
        "improvements": verdicts.count("improvement"),
    }


def _comparison_text(comparison: dict[str, Any], base: dict[str, Any]) -> str:
    lines = [
        f"base      {comparison['base']['run_id']} ({str((comparison['base']['source'] or {}).get('revision'))[:12]})",
        f"candidate {comparison['candidate']['run_id']} ({str((comparison['candidate']['source'] or {}).get('revision'))[:12]})",
    ]
    for warning in comparison["warnings"]:
        lines.append(f"warning: {warning}")
    lines.append("")
    width = max((len(metric_id) for metric_id in comparison["metrics"]), default=10)
    for metric_id, result in comparison["metrics"].items():
        verdict = result["verdict"]
        if "delta" not in result:
            lines.append(f"{metric_id:<{width}}  {verdict}")
            continue
        unit = base["metrics"][metric_id]["unit"]
        lines.append(
            f"{metric_id:<{width}}  {verdict:<11}  "
            f"{_format(result['base_median'], unit)} -> {_format(result['candidate_median'], unit)}  "
            f"({result['relative'] * 100:+.1f}%, noise ±{_format(result['noise_bound'], unit)})"
        )
    lines.append("")
    lines.append(f"{comparison['regressions']} regression(s), {comparison['improvements']} improvement(s)")
    return "\n".join(lines) + "\n"


def status_text() -> str:
    root = profile_root()
    lines = [f"Profile results: {root}"]
    for tool in TOOLS:
        latest = root / tool / "latest"
        if not latest.exists():
            lines.append(f"{tool}: no runs")
            continue
        try:
            report = load_report(latest)
        except ReportError as error:
            lines.append(f"{tool}: latest run unreadable ({error})")
            continue
        lines.append(
            f"{tool}: latest {report['scenario']} run {report['run_id']} at {report['created_at']} "
            f"({len(report['metrics'])} metrics) -> {latest.resolve()}"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tron_profile_report.py")
    commands = parser.add_subparsers(dest="command", required=True)

    write = commands.add_parser("write", help="build and write a report from raw samples")
    write.add_argument("--tool", required=True, choices=TOOLS)
    write.add_argument("--scenario", required=True)
    write.add_argument("--samples", required=True, type=Path)
    write.add_argument("--run-dir", required=True, type=Path)
    write.add_argument("--worktree", required=True, type=Path)
    write.add_argument("--artifact", action="append", default=[], metavar="NAME=PATH")

    compare_parser = commands.add_parser("compare", help="compare a candidate report with a base report")
    compare_parser.add_argument("base", type=Path)
    compare_parser.add_argument("candidate", type=Path)
    compare_parser.add_argument("--floor", type=float, default=DEFAULT_FLOOR)
    compare_parser.add_argument("--json", action="store_true")
    compare_parser.add_argument("--allow-mismatch", action="store_true")

    commands.add_parser("status", help="show the latest report of each tool")
    commands.add_parser("environment", help="print the host environment record")
    args = parser.parse_args(argv)

    try:
        if args.command == "write":
            try:
                samples = json.loads(args.samples.read_text())
            except (OSError, json.JSONDecodeError) as error:
                raise ReportError(f"cannot read samples {args.samples}: {error}") from error
            artifacts = {}
            for item in args.artifact:
                name, separator, value = item.partition("=")
                if not separator or not name:
                    raise ReportError(f"invalid --artifact {item!r}")
                artifacts[name] = value
            report = build_report(
                args.tool, args.scenario, samples, args.worktree.resolve(), args.run_dir.name, artifacts
            )
            destination = write_report(report, args.run_dir)
            sys.stdout.write(markdown_summary(report))
            sys.stdout.write(f"\nReport: {destination}\n")
            return EXIT_OK
        if args.command == "compare":
            if not (0 <= args.floor < 1):
                raise ReportError("--floor must be in [0, 1)")
            base, candidate = load_report(args.base), load_report(args.candidate)
            comparison = compare(base, candidate, args.floor, args.allow_mismatch)
            if args.json:
                sys.stdout.write(json.dumps(comparison, indent=2, sort_keys=True) + "\n")
            else:
                sys.stdout.write(_comparison_text(comparison, base))
            return EXIT_REGRESSION if comparison["regressions"] else EXIT_OK
        if args.command == "status":
            sys.stdout.write(status_text())
            return EXIT_OK
        if args.command == "environment":
            sys.stdout.write(json.dumps(environment(), indent=2, sort_keys=True) + "\n")
            return EXIT_OK
    except ReportError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_INVALID
    return EXIT_INVALID


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
