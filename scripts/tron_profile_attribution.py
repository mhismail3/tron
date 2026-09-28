#!/usr/bin/env python3
"""xctrace recording and attribution summaries for scripts/tron-profile.

`scripts/tron-profile ios --trace` and `scripts/tron-profile device --attach`
record an Instruments trace with `xcrun xctrace`, then this module exports its
tables (`xctrace export --toc` / `--xpath`) and writes `attribution.json` and
`attribution.md`: where the process spent CPU (top symbols by self and total
time for all threads and for the main thread, per-thread share), which SwiftUI
view bodies ran how often, and the app's signpost intervals. Scenario traces are
restricted to the measured windows the hosted test reports as wall-clock bounds
(mapped onto the trace through its start date), so setup and teardown between
iterations never enter the attribution. Frames Instruments could not
symbolicate are named as unresolved addresses per image, never dropped.

Exports are streamed: a host-wide Time Profiler export of a loaded Mac runs to
gigabytes, so rows are read one at a time and every value carrying an `id` is
kept once, however often later rows repeat it by reference.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import io
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Iterator
import xml.etree.ElementTree as ElementTree

SCHEMA = "tron.profile-attribution.v1"
APP_SUBSYSTEM = "com.tron.mobile"
# Images whose frames name Tron's own owners. Inclusive main-thread time is
# also ranked over these alone, because the harness and run-loop frames above
# them hold ~100% and would otherwise fill the ranking.
APP_IMAGES = ("TronMobile",)
TOP_SYMBOLS = 25
TOP_THREADS = 15
TOP_VIEWS = 30
EXPORT_TIMEOUT_SECONDS = 900

# Scenario template name -> (recording target, xctrace --template or None for
# the blank template, extra --instrument names).
#   host: `--all-processes` on this Mac, filtered to the test host's pid. The
#     host kernel samples simulator processes and symbolicates their images;
#     it cannot read the simulator's logd, so it carries no app signposts.
#   simulator: `--device <simulator> --attach <pid>`; carries signposts and
#     SwiftUI data. In the environment where this was built, simulator-device
#     recording never started (see packages/ios-app/docs/development.md).
TEMPLATES: dict[str, tuple[str, str | None, tuple[str, ...]]] = {
    "time-profiler": ("host", "Time Profiler", ()),
    "swiftui": ("simulator", "SwiftUI", ("os_signpost",)),
    "points-of-interest": ("simulator", None, ("os_signpost", "Points of Interest")),
}
# `scripts/tron-profile device --attach` templates: (xctrace --template, extra instruments).
DEVICE_TEMPLATES: dict[str, tuple[str | None, tuple[str, ...]]] = {
    "time-profiler": ("Time Profiler", ("os_signpost",)),
    "power-profiler": ("Power Profiler", ("os_signpost",)),
}

UNRESOLVED_ADDRESS = re.compile(r"^0x[0-9a-fA-F]+$")


class AttributionError(Exception):
    pass


# ------------------------------------------------------------------ export ---

class Table:
    """One exported xctrace table: the column mnemonics, indexed by position.

    `iter_rows` hands rows to callers with every reference already replaced by
    its defining element. A `<sentinel/>` cell (no value) reads as None.
    """

    def __init__(self, schema: str, columns: list[str]) -> None:
        self.schema = schema
        self.columns = columns
        self._index = {name: position for position, name in enumerate(columns)}

    @staticmethod
    def value(element: ElementTree.Element | None) -> ElementTree.Element | None:
        """The element itself, or None for an absent or `<sentinel/>` cell."""
        return None if element is None or element.tag == "sentinel" else element

    def cell(self, row: list[ElementTree.Element], column: str) -> ElementTree.Element | None:
        position = self._index.get(column)
        if position is None or position >= len(row):
            return None
        return self.value(row[position])

    def has(self, *columns: str) -> bool:
        return all(column in self._index for column in columns)


Rows = Iterable[tuple[Table, list[ElementTree.Element]]]


def iter_rows(source: bytes | str | Path) -> Iterator[tuple[Table, list[ElementTree.Element]]]:
    """Stream `(table, row cells)` from `xctrace export --xpath` output.

    `source` is the XML itself (bytes/str) or a path to it. xctrace writes each
    distinct value once with an `id` and repeats it as `<element ref="id"/>`,
    possibly many rows later, so elements carrying an `id` stay in a map. When
    an element ends, each reference among its children is replaced by the
    shared definition: memory then grows with distinct values, not with
    references (a host-wide export repeats frames ~15 M times, which kept per
    reference took the profiler past 5 GB). Each row is detached once consumed.
    """
    stream = Path(source).open("rb") if isinstance(source, Path) else io.BytesIO(
        source.encode() if isinstance(source, str) else source)
    elements: dict[str, ElementTree.Element] = {}
    table: Table | None = None
    node: ElementTree.Element | None = None
    root_seen = False
    try:
        for event, element in ElementTree.iterparse(stream, events=("start", "end")):
            if event == "start":
                if not root_seen:
                    root_seen = True
                    if element.tag != "trace-query-result":
                        raise AttributionError(f"unexpected xctrace export root <{element.tag}>")
                elif element.tag == "node":
                    node, table = element, None
                continue
            for position, child in enumerate(element):
                reference = child.get("ref")
                if reference is not None:
                    definition = elements.get(reference)
                    if definition is None:
                        raise AttributionError(f"{table.schema if table else 'export'}: reference to undefined "
                                               f"element id {reference}")
                    element[position] = definition
            identifier = element.get("id")
            if identifier is not None:
                elements[identifier] = element
            if element.tag == "schema" and node is not None:
                columns = [column.findtext("mnemonic") or "" for column in element.findall("col")]
                table = Table(element.get("name") or "", columns)
            elif element.tag == "row":
                if table is None:
                    raise AttributionError("xctrace export row precedes its <schema>; the export format changed")
                yield table, list(element)
                if node is not None:
                    node.remove(element)
    except ElementTree.ParseError as error:
        raise AttributionError(f"xctrace export is not valid XML: {error}") from error
    finally:
        stream.close()


def number(element: ElementTree.Element | None) -> float | None:
    if element is None or element.text is None:
        return None
    try:
        return float(element.text)
    except ValueError:
        return None


def text(element: ElementTree.Element | None) -> str | None:
    if element is None:
        return None
    return element.get("fmt") or element.text


def run_bounded(command: list[str], timeout: float) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AttributionError(f"{' '.join(command[:4])} exceeded {timeout:.0f} s") from error


def export_toc(trace: Path) -> ElementTree.Element:
    result = run_bounded(["xcrun", "xctrace", "export", "--input", str(trace), "--toc"], EXPORT_TIMEOUT_SECONDS)
    if result.returncode:
        raise AttributionError(f"xctrace export --toc failed: {result.stderr.decode(errors='replace').strip()}"
                               f"{result.stdout.decode(errors='replace').strip()}")
    try:
        return ElementTree.fromstring(result.stdout)
    except ElementTree.ParseError as error:
        raise AttributionError(f"xctrace table of contents is not valid XML: {error}") from error


def export_rows(trace: Path, schema: str, run_number: int = 1) -> Iterator[tuple[Table, list[ElementTree.Element]]]:
    """Export one schema to a temporary file beside the trace and stream it."""
    query = f'/trace-toc/run[@number="{run_number}"]/data/table[@schema="{schema}"]'
    handle, name = tempfile.mkstemp(prefix=f".export-{schema}-", suffix=".xml", dir=trace.parent)
    os.close(handle)
    output = Path(name)
    try:
        result = run_bounded(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath", query,
                              "--output", str(output)], EXPORT_TIMEOUT_SECONDS)
        if result.returncode:
            raise AttributionError(f"xctrace export of {schema} failed: "
                                   f"{(result.stderr or result.stdout).decode(errors='replace').strip()}")
        yield from iter_rows(output)
    finally:
        output.unlink(missing_ok=True)


def toc_schemas(toc: ElementTree.Element) -> list[str]:
    return sorted({table.get("schema") or "" for table in toc.iter("table")} - {""})


def toc_target_pid(toc: ElementTree.Element) -> int | None:
    """The attached or launched process of the first run, if the trace names one."""
    process = toc.find("run/info/target/process")
    try:
        return int(process.get("pid")) if process is not None and process.get("pid") else None
    except ValueError:
        return None


def toc_start_epoch(toc: ElementTree.Element) -> float:
    """Wall-clock start of the first run; trace times are nanoseconds after it."""
    value = toc.findtext("run/info/summary/start-date")
    if not value:
        raise AttributionError("the trace table of contents has no start date; cannot place the measured windows")
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError as error:
        raise AttributionError(f"unreadable trace start date {value!r}") from error


# ----------------------------------------------------------------- windows ---

def signpost_intervals(rows: Rows) -> list[dict[str, Any]]:
    """Rows of `os-signpost-interval` tables as plain dictionaries (ns)."""
    intervals = []
    for table, row in rows:
        if not table.has("start", "duration", "name", "subsystem"):
            raise AttributionError(
                f"{table.schema} lacks start/duration/name/subsystem columns ({table.columns}); "
                "the xctrace export schema changed"
            )
        start, duration = number(table.cell(row, "start")), number(table.cell(row, "duration"))
        if start is None or duration is None:
            continue  # an interval still open when the recording stopped
        intervals.append({
            "start": start,
            "duration": duration,
            "name": text(table.cell(row, "name")) or "",
            "subsystem": text(table.cell(row, "subsystem")) or "",
            "category": text(table.cell(row, "category")) or "",
            "pid": _pid(table, row, "process"),
        })
    intervals.sort(key=lambda item: item["start"])
    return intervals


def _pid(table: Table, row: list[ElementTree.Element], column: str) -> int | None:
    process = table.cell(row, column)
    if process is None:
        return None
    pid = table.value(process.find("pid"))
    value = number(pid)
    return int(value) if value is not None else None


def trace_windows(windows_epoch: list[tuple[float, float]], start_epoch: float) -> list[tuple[float, float]]:
    """Wall-clock window bounds (seconds) as trace times (ns after the start)."""
    windows = []
    for start, end in windows_epoch:
        if not end > start:
            raise AttributionError(f"measured window ends before it starts: {start} .. {end}")
        windows.append(((start - start_epoch) * 1e9, (end - start_epoch) * 1e9))
    return windows


def inside(time: float, windows: list[tuple[float, float]] | None) -> bool:
    if windows is None:
        return True
    return any(start <= time < end for start, end in windows)


# ------------------------------------------------------------ time profile ---

def frame_symbol(frame: ElementTree.Element, table: Table) -> tuple[str, str, bool]:
    """(symbol, image, resolved) for one backtrace frame.

    An unsymbolicated frame keeps its identity as the image it belongs to, so
    unresolved app or test frames stay visible in the ranking instead of
    vanishing.
    """
    binary = table.value(frame.find("binary"))
    image = binary.get("name") if binary is not None and binary.get("name") else "unknown image"
    name = frame.get("name") or ""
    if not name or UNRESOLVED_ADDRESS.match(name):
        return f"<unresolved address in {image}>", image, False
    return name, image, True


def summarize_time_profile(rows: Rows, windows: list[tuple[float, float]] | None,
                           pid: int | None, top: int = TOP_SYMBOLS,
                           discarded: list[tuple[float, float]] | None = None) -> dict[str, Any]:
    """Self and inclusive time per symbol, all threads and main thread, plus
    per-thread CPU. Weights are the sampled CPU time each row represents."""
    self_all: Counter[tuple[str, str]] = Counter()
    total_all: Counter[tuple[str, str]] = Counter()
    self_main: Counter[tuple[str, str]] = Counter()
    total_main: Counter[tuple[str, str]] = Counter()
    threads: Counter[str] = Counter()
    outside_self: Counter[tuple[str, str]] = Counter()
    images: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])  # image -> [resolved, unresolved] weight
    weight_all = weight_main = 0.0
    samples = outside = foreign = in_discarded = 0
    main_names: set[str] = set()
    for table, row in rows:
        if not table.has("time", "thread", "weight", "stack"):
            raise AttributionError(
                f"time-profile lacks time/thread/weight/stack columns ({table.columns}); the xctrace export schema changed"
            )
        time = number(table.cell(row, "time"))
        if time is None:
            continue
        if pid is not None and _pid(table, row, "process") not in (None, pid):
            foreign += 1
            continue
        weight = number(table.cell(row, "weight")) or 0.0
        if discarded and inside(time, discarded):
            in_discarded += 1  # XCTest's warm-up iteration: measured by nobody
            continue
        if not inside(time, windows):
            outside += 1
            leaf = next(iter(_frames(table, table.cell(row, "stack"))), None)
            outside_self[frame_symbol(leaf, table)[:2] if leaf is not None else ("<no backtrace>", "")] += weight
            continue
        thread = text(table.cell(row, "thread")) or "unknown thread"
        main = thread.startswith("Main Thread")
        if main:
            main_names.add(thread)
        samples += 1
        weight_all += weight
        threads[thread] += weight
        frames = _frames(table, table.cell(row, "stack"))
        keys = []
        for frame in frames:
            symbol, image, resolved = frame_symbol(frame, table)
            keys.append((symbol, image))
            images[image][0 if resolved else 1] += weight
        if keys:
            self_all[keys[0]] += weight
        else:
            self_all[("<no backtrace>", "")] += weight
        unique = set(keys)
        for key in unique:
            total_all[key] += weight
        if main:
            weight_main += weight
            if keys:
                self_main[keys[0]] += weight
            else:
                self_main[("<no backtrace>", "")] += weight
            for key in unique:
                total_main[key] += weight
    if samples == 0:
        raise AttributionError(
            "the time profile has no samples inside the measured windows"
            + (f" ({outside} outside, {foreign} from other processes)" if outside or foreign else "")
        )

    def ranked(counter: Counter[tuple[str, str]], denominator: float) -> list[dict[str, Any]]:
        return [
            {"symbol": symbol, "image": image, "ms": round(value / 1e6, 3),
             "share": round(value / denominator, 4) if denominator else 0.0}
            for (symbol, image), value in counter.most_common(top)
        ]

    unresolved = sum(values[1] for values in images.values())
    return {
        "samples": samples,
        "samples_outside_windows": outside,
        "samples_in_discarded_windows": in_discarded,
        "samples_other_processes": foreign,
        # This process's leaf symbols just outside the windows (setup,
        # readiness, teardown): excluded from every ranking below.
        "outside_windows_self": ranked(outside_self, sum(outside_self.values()))[:10],
        "cpu_ms": round(weight_all / 1e6, 3),
        "main_thread_cpu_ms": round(weight_main / 1e6, 3),
        "main_thread": sorted(main_names),
        "threads": [
            {"thread": thread, "ms": round(value / 1e6, 3), "share": round(value / weight_all, 4)}
            for thread, value in threads.most_common(TOP_THREADS)
        ],
        "all_threads": {"self": ranked(self_all, weight_all), "total": ranked(total_all, weight_all)},
        "main_thread_symbols": {
            "self": ranked(self_main, weight_main),
            "total": ranked(total_main, weight_main),
            "app_total": ranked(Counter({key: value for key, value in total_main.items() if key[1] in APP_IMAGES}),
                                weight_main),
        },
        # Weight in frames of each image; an unresolved share in the app or
        # test image means symbols are missing for the profiled build.
        "symbolication": {
            image: {"resolved_ms": round(values[0] / 1e6, 3), "unresolved_ms": round(values[1] / 1e6, 3)}
            for image, values in sorted(images.items(), key=lambda item: -sum(item[1]))[:TOP_THREADS]
        },
        "unresolved_frame_share": round(unresolved / max(sum(sum(v) for v in images.values()), 1.0), 4),
    }


def _frames(table: Table, stack: ElementTree.Element | None) -> list[ElementTree.Element]:
    if stack is None:
        return []
    backtrace = stack if stack.tag == "backtrace" else table.value(stack.find("backtrace"))
    if backtrace is None:
        return []
    return [frame for frame in (table.value(child) for child in backtrace.findall("frame")) if frame is not None]


# -------------------------------------------------------------- signposts ---

def summarize_signposts(intervals: list[dict[str, Any]], windows: list[tuple[float, float]] | None,
                        pid: int | None) -> dict[str, Any]:
    """The app's (`com.tron.mobile`) signpost intervals that start inside the
    measured windows, grouped by category and name."""
    groups: dict[tuple[str, str], list[float]] = defaultdict(list)
    for item in intervals:
        if item["subsystem"] != APP_SUBSYSTEM or not inside(item["start"], windows):
            continue
        if pid is not None and item["pid"] not in (None, pid):
            continue
        groups[(item["category"], item["name"])].append(item["duration"])
    rows = []
    for (category, name), durations in sorted(groups.items(), key=lambda entry: -sum(entry[1])):
        rows.append({
            "category": category, "name": name, "count": len(durations),
            "total_ms": round(sum(durations) / 1e6, 3),
            "median_ms": round(statistics.median(durations) / 1e6, 3),
            "max_ms": round(max(durations) / 1e6, 3),
        })
    return {"subsystem": APP_SUBSYSTEM, "intervals": rows}


# ---------------------------------------------------------------- swiftui ---

# Columns that name the view (or attribute graph node) in SwiftUI tables and
# the columns that carry a duration; the SwiftUI instrument's export schema was
# not observable where this was written (simulator recording never started),
# so the summary names what it found instead of assuming one layout.
SWIFTUI_NAME_COLUMNS = ("view-name", "view", "description", "name", "type", "view-type")
SWIFTUI_DURATION_COLUMNS = ("duration", "time-duration")


def summarize_swiftui(rows_by_schema: dict[str, Rows], windows: list[tuple[float, float]] | None,
                      top: int = TOP_VIEWS) -> dict[str, Any]:
    tables: dict[str, Any] = {}
    for schema, rows in sorted(rows_by_schema.items()):
        counts: Counter[str] = Counter()
        durations: Counter[str] = Counter()
        name_column = duration_column = None
        rows_seen = 0
        for table, row in rows:
            if name_column is None:
                name_column = next((column for column in SWIFTUI_NAME_COLUMNS if table.has(column)), "")
                duration_column = next((column for column in SWIFTUI_DURATION_COLUMNS if table.has(column)), "")
            time = number(table.cell(row, "start")) or number(table.cell(row, "time"))
            if time is not None and not inside(time, windows):
                continue
            rows_seen += 1
            name = text(table.cell(row, name_column)) if name_column else None
            counts[name or "<unnamed>"] += 1
            if duration_column:
                durations[name or "<unnamed>"] += number(table.cell(row, duration_column)) or 0.0
        tables[schema] = {
            "rows": rows_seen, "name_column": name_column or None, "duration_column": duration_column or None,
            "views": [{"view": view, "count": count, "total_ms": round(durations[view] / 1e6, 3)}
                      for view, count in counts.most_common(top)],
        }
    return tables


# ------------------------------------------------------------------ power ---

POWER_SCHEMA = re.compile(r"power|energy|thermal", re.IGNORECASE)


def summarize_numeric_tables(rows_by_schema: dict[str, Rows]) -> dict[str, Any]:
    """Schema-agnostic summary (rows; count, sum, mean and max of each numeric
    column) of the Power Profiler's tables. Their schemas are only exported
    from a physical device, so this reads whatever columns they carry rather
    than assuming names."""
    summary: dict[str, Any] = {}
    for schema, rows in sorted(rows_by_schema.items()):
        columns: dict[str, list[float]] = defaultdict(list)
        count = 0
        for table, row in rows:
            count += 1
            for column in table.columns:
                value = number(table.cell(row, column))
                if value is not None:
                    columns[column].append(value)
        summary[schema] = {
            "rows": count,
            "numeric_columns": {
                column: {"count": len(values), "sum": sum(values), "mean": sum(values) / len(values), "max": max(values)}
                for column, values in sorted(columns.items())
            },
        }
    return summary


# ------------------------------------------------------------------ driver ---

def attribute(trace: Path, template: str, pid: int | None, windows_epoch: list[tuple[float, float]] | None,
              top: int = TOP_SYMBOLS, discarded_epoch: list[tuple[float, float]] | None = None) -> dict[str, Any]:
    """Export `trace` and build the attribution document.

    `windows_epoch` are the measured windows as wall-clock seconds (scenario
    traces); None attributes the whole recording (device attach).
    `discarded_epoch` are windows XCTest ran but did not report (warm-up);
    their samples are counted apart, neither measured nor "outside".
    """
    toc = export_toc(trace)
    schemas = toc_schemas(toc)
    warnings: list[str] = []
    if pid is None:
        pid = toc_target_pid(toc)
    windows = trace_windows(windows_epoch, toc_start_epoch(toc)) if windows_epoch is not None else None
    discarded = trace_windows(discarded_epoch, toc_start_epoch(toc)) if discarded_epoch else None
    document: dict[str, Any] = {
        "schema": SCHEMA,
        "trace": str(trace),
        "template": template,
        "pid": pid,
        "windows": [
            {"start_ms": round(start / 1e6, 3), "duration_ms": round((end - start) / 1e6, 3)}
            for start, end in (windows or [])
        ],
        "scope": "measured windows" if windows is not None else "whole recording",
        "tables": schemas,
        "warnings": warnings,
    }
    if windows and windows[0][0] < 0:
        raise AttributionError("the first measured window starts before the recording; the capture missed part of it")
    if "time-profile" in schemas:
        document["time_profile"] = summarize_time_profile(export_rows(trace, "time-profile"), windows, pid, top,
                                                          discarded)
    elif template == "time-profiler":
        raise AttributionError(f"the time-profiler trace has no time-profile table (tables: {', '.join(schemas)})")
    if template == "swiftui":
        swiftui_schemas = [schema for schema in schemas if schema.startswith("swiftui")]
        if swiftui_schemas:
            document["swiftui"] = summarize_swiftui(
                {schema: export_rows(trace, schema) for schema in swiftui_schemas}, windows, top)
        else:
            document["swiftui"] = None
            warnings.append(f"SwiftUI data unavailable: the trace exports no swiftui table (tables: {', '.join(schemas)})")
    if template == "power-profiler":
        power = [schema for schema in schemas if POWER_SCHEMA.search(schema)]
        if not power:
            warnings.append(f"the trace exports no power, energy or thermal table (tables: {', '.join(schemas)})")
        document["power"] = summarize_numeric_tables({schema: export_rows(trace, schema) for schema in power})
    if "os-signpost-interval" in schemas:
        document["signposts"] = summarize_signposts(signpost_intervals(export_rows(trace, "os-signpost-interval")),
                                                    windows, pid)
    else:
        document["signposts"] = None
        warnings.append("app signposts unavailable: this recording has no os_signpost data "
                        "(a host-wide recording cannot read the simulator's logd)")
    return document


def markdown(document: dict[str, Any], top: int = 15) -> str:
    lines = [f"# Attribution: {document['template']}", "",
             f"- Trace: `{document['trace']}`",
             f"- Scope: {document['scope']}"
             + (f" ({len(document['windows'])} windows)" if document["windows"] else "")]
    for warning in document["warnings"]:
        lines.append(f"- Warning: {warning}")
    profile = document.get("time_profile")
    if profile:
        lines += ["", f"CPU sampled: {profile['cpu_ms']:.1f} ms, main thread {profile['main_thread_cpu_ms']:.1f} ms "
                  f"({profile['samples']} samples); unresolved frame share {profile['unresolved_frame_share']:.1%}"]
        for title, ranking in (("Main thread, self time", profile["main_thread_symbols"]["self"]),
                               (f"Main thread, total time in {', '.join(APP_IMAGES)}",
                                profile["main_thread_symbols"]["app_total"]),
                               ("Main thread, total time", profile["main_thread_symbols"]["total"]),
                               ("All threads, self time", profile["all_threads"]["self"]),
                               ("All threads, total time", profile["all_threads"]["total"])):
            lines += ["", f"## {title}", "", "| ms | share | symbol | image |", "| ---: | ---: | --- | --- |"]
            for row in ranking[:top]:
                lines.append(f"| {row['ms']:.1f} | {row['share']:.1%} | `{_cell(row['symbol'])}` | {row['image']} |")
        lines += ["", "## Threads", "", "| ms | share | thread |", "| ---: | ---: | --- |"]
        for row in profile["threads"]:
            lines.append(f"| {row['ms']:.1f} | {row['share']:.1%} | {_cell(row['thread'])} |")
    for schema, table in (document.get("power") or {}).items():
        lines += ["", f"## Power: {schema} ({table['rows']} rows)", "", "| column | count | sum | mean | max |",
                  "| --- | ---: | ---: | ---: | ---: |"]
        for column, values in table["numeric_columns"].items():
            lines.append(f"| {column} | {values['count']} | {values['sum']:.4g} | {values['mean']:.4g} | "
                         f"{values['max']:.4g} |")
    for schema, table in (document.get("swiftui") or {}).items():
        lines += ["", f"## SwiftUI: {schema} ({table['rows']} rows, by {table['name_column']})", "",
                  "| count | total ms | view |", "| ---: | ---: | --- |"]
        for row in table["views"][:top]:
            lines.append(f"| {row['count']} | {row['total_ms']:.1f} | `{_cell(row['view'])}` |")
    if document.get("signposts") is None:
        return "\n".join(lines) + "\n"
    signposts = document["signposts"]["intervals"]
    lines += ["", f"## Signpost intervals ({APP_SUBSYSTEM})", ""]
    if signposts:
        lines += ["| category | name | count | total ms | median ms | max ms |", "| --- | --- | ---: | ---: | ---: | ---: |"]
        for row in signposts:
            lines.append(f"| {row['category']} | {row['name']} | {row['count']} | {row['total_ms']:.1f} | "
                         f"{row['median_ms']:.2f} | {row['max_ms']:.2f} |")
    else:
        lines.append("None inside the measured scope.")
    return "\n".join(lines) + "\n"


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("`", "'")


def load_windows(path: Path, expected: int | None,
                 skip: int) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    """(measured, discarded) windows from the hosted test's `windows.jsonl`:
    XCTest runs `skip` (one) extra measure invocation first and discards it."""
    try:
        entries = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        windows = [(float(entry["start"]), float(entry["end"])) for entry in entries]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise AttributionError(f"unreadable measured windows {path}: {error}") from error
    if expected is not None and len(windows) != expected + skip:
        raise AttributionError(
            f"{path} lists {len(windows)} windows; {expected} measured iterations need {expected + skip} "
            f"(including {skip} discarded warm-up)"
        )
    return windows[skip:], windows[:skip]


def write(document: dict[str, Any], directory: Path) -> tuple[Path, Path]:
    json_path, markdown_path = directory / "attribution.json", directory / "attribution.md"
    json_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    markdown_path.write_text(markdown(document))
    return json_path, markdown_path


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="tron_profile_attribution.py",
        description="Re-summarize an existing .trace (for example after a parser fix) into attribution.json/.md.",
    )
    parser.add_argument("trace", type=Path)
    parser.add_argument("--template", required=True, choices=sorted({*TEMPLATES, *DEVICE_TEMPLATES}))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--windows", type=Path,
                        help="windows.jsonl of a scenario trace (trace-handshake/); default: whole recording")
    parser.add_argument("--skip-windows", type=int, default=1,
                        help="leading windows to drop (XCTest's discarded first iteration; default 1)")
    parser.add_argument("--output-dir", type=Path, help="default: the trace's directory")
    arguments = parser.parse_args(argv)
    try:
        windows, discarded = load_windows(arguments.windows, None, arguments.skip_windows) \
            if arguments.windows else (None, None)
        document = attribute(arguments.trace, arguments.template, arguments.pid, windows, discarded_epoch=discarded)
        paths = write(document, arguments.output_dir or arguments.trace.parent)
    except AttributionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(markdown(document))
    print(f"\nAttribution: {paths[0]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
