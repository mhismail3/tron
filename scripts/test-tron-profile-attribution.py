#!/usr/bin/env python3
"""Failure-mode tests for xctrace export parsing in tron_profile_attribution.py.

`scripts/tron-profile ios --self-test --trace time-profiler` proves attribution
end to end on the success path. These cases target the ways the export step
could still point an agent at the wrong owner without any simulator:

1. A value written once (`id`) and repeated by reference (`ref`) in later rows
   is not resolved, so repeated threads, stacks or frames lose their weight.
2. Frames Instruments could not symbolicate are dropped or merged into a real
   symbol instead of being named as unresolved addresses of their image.
3. Samples outside the measured windows (setup, teardown, readiness between
   iterations, XCTest's discarded warm-up iteration) or from another process
   (a host-wide recording samples every process) leak into the ranking.
4. An empty time profile, or none inside the windows, yields an empty ranking
   that reads as "nothing costs anything" instead of failing.
5. An export schema change (a renamed or missing column) is read as zero
   instead of failing.
6. A recording that missed a measured window, or a window list that does
   not match the measured iterations, is attributed as if complete.
7. Recursion counts a frame's inclusive time more than once per sample.
8. The self-test accepts a traced control run whose known workload function is
   not among the top self-time symbols, or whose windows are misplaced so the
   workload shows up outside them.
9. Parsing retains memory per reference instead of per definition: every
   `<frame ref>` inside a retained backtrace stays its own element, so a
   host-wide export (15 M frame references on a loaded Mac) takes the profiler
   past 5 GB.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile
import tracemalloc
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import tron_profile_attribution as attribution  # noqa: E402

loader = importlib.machinery.SourceFileLoader("tron_profile_ios", str(ROOT / "scripts/tron-profile-ios"))
spec = importlib.util.spec_from_loader(loader.name, loader)
profiler = importlib.util.module_from_spec(spec)
loader.exec_module(profiler)

TIME_PROFILE_COLUMNS = ("time", "thread", "process", "core", "thread-state", "weight", "stack")
INTERVAL_COLUMNS = ("start", "duration", "layout-qualifier", "name", "category", "subsystem", "identifier", "process")
TOC = ('<trace-toc><run number="1"><info><summary><start-date>2026-09-27T14:32:53.000-07:00</start-date>'
       '</summary></info><data><table schema="time-profile"/></data></run></trace-toc>')
TOC_EPOCH = 1790544773.0


def schema(name: str, columns: tuple[str, ...]) -> str:
    return f'<schema name="{name}">' + "".join(f"<col><mnemonic>{column}</mnemonic></col>" for column in columns) + "</schema>"


def result(name: str, columns: tuple[str, ...], rows: list[str]) -> str:
    return ('<?xml version="1.0"?><trace-query-result><node xpath="x">' + schema(name, columns)
            + "".join(rows) + "</node></trace-query-result>")


class Samples:
    """Builds time-profile rows the way xctrace writes them: the first use of a
    value defines an id, later uses repeat it as a bare reference."""

    def __init__(self) -> None:
        self.defined: dict[str, int] = {}

    def value(self, key: str, tag: str, attributes: str, inner: str) -> str:
        if key in self.defined:
            return f'<{tag} ref="{self.defined[key]}"/>'
        self.defined[key] = len(self.defined) + 1
        return f'<{tag} id="{self.defined[key]}" {attributes}>{inner}</{tag}>'

    def process(self, pid: int) -> str:
        return self.value(f"process{pid}", "process", f'fmt="TronMobile ({pid})"', f'<pid fmt="{pid}">{pid}</pid>')

    def frame(self, name: str, image: str | None) -> str:
        binary = self.value(f"binary{image}", "binary", f'name="{image}" path="/x/{image}"', "") if image else ""
        return self.value(f"frame{name}@{image}", "frame", f'name="{name}" addr="0x1"', binary)

    def row(self, time_ns: int, thread: str, frames: list[tuple[str, str | None]], pid: int = 42,
            weight_ns: int = 1_000_000) -> str:
        backtrace = "<backtrace>" + "".join(self.frame(name, image) for name, image in frames) + "</backtrace>"
        stack = self.value("stack" + "|".join(f"{name}@{image}" for name, image in frames),
                           "tagged-backtrace", 'fmt="s"', backtrace)
        thread_xml = self.value(f"thread{thread}{pid}", "thread", f'fmt="{thread}"',
                                f'<tid fmt="1">1</tid>{self.process(pid)}')
        return ("<row>" + f'<sample-time fmt="t">{time_ns}</sample-time>' + thread_xml + self.process(pid)
                + '<core fmt="c">0</core><thread-state fmt="Running">Running</thread-state>'
                + self.value(f"weight{weight_ns}", "weight", 'fmt="w"', str(weight_ns)) + stack + "</row>")


MAIN = "Main Thread 0x1 (TronMobile, pid: 42)"
WORKER = "com.apple.worker 0x2 (TronMobile, pid: 42)"


def interval(start: int, duration: int, name: str, subsystem: str, category: str = "Profile", pid: int = 42) -> str:
    return (f'<row><start-time fmt="s">{start}</start-time><duration fmt="d">{duration}</duration><sentinel/>'
            f'<string fmt="{name}">{name}</string><category fmt="{category}">{category}</category>'
            f'<subsystem fmt="{subsystem}">{subsystem}</subsystem><os-signpost-identifier>1</os-signpost-identifier>'
            f'<process fmt="p"><pid fmt="{pid}">{pid}</pid></process></row>')


def time_profile(rows: list[str]) -> list:
    return list(attribution.iter_rows(result("time-profile", TIME_PROFILE_COLUMNS, rows)))


class ExportParsing(unittest.TestCase):
    def test_references_carry_their_weight(self) -> None:
        samples = Samples()
        rows = [samples.row(time, MAIN, [("render()", "TronMobile"), ("main", "TronMobile")]) for time in range(0, 5_000_000, 1_000_000)]
        summary = attribution.summarize_time_profile(time_profile(rows), None, 42)
        self.assertEqual(summary["samples"], 5)
        self.assertEqual(summary["main_thread_symbols"]["self"][0], {
            "symbol": "render()", "image": "TronMobile", "ms": 5.0, "share": 1.0})
        self.assertEqual(summary["main_thread_cpu_ms"], 5.0)

    def test_unresolved_frames_are_named_per_image(self) -> None:
        samples = Samples()
        rows = [
            samples.row(1, MAIN, [("0x10428b079", "TronMobile"), ("main", "TronMobile")]),
            samples.row(2, MAIN, [("0x10428b079", "TronMobile"), ("main", "TronMobile")]),
            samples.row(3, WORKER, [("0x2000", None)]),
            samples.row(4, WORKER, [("", "libswiftCore.dylib")]),
        ]
        summary = attribution.summarize_time_profile(time_profile(rows), None, 42)
        symbols = {row["symbol"]: row["ms"] for row in summary["all_threads"]["self"]}
        self.assertEqual(symbols["<unresolved address in TronMobile>"], 2.0)
        self.assertEqual(symbols["<unresolved address in unknown image>"], 1.0)
        self.assertEqual(symbols["<unresolved address in libswiftCore.dylib>"], 1.0)
        self.assertEqual(summary["symbolication"]["TronMobile"], {"resolved_ms": 2.0, "unresolved_ms": 2.0})
        self.assertGreater(summary["unresolved_frame_share"], 0)

    def test_only_samples_inside_windows_and_of_the_process_count(self) -> None:
        samples = Samples()
        rows = [
            samples.row(2, MAIN, [("warmup()", "TronMobile")]),
            samples.row(5, MAIN, [("setup()", "TronMobileTests")]),
            samples.row(15, MAIN, [("measured()", "TronMobile")]),
            samples.row(16, MAIN, [("otherProcess()", "Other")], pid=7),
            samples.row(25, MAIN, [("teardown()", "TronMobileTests")]),
            samples.row(35, MAIN, [("measured()", "TronMobile")]),
        ]
        summary = attribution.summarize_time_profile(time_profile(rows), [(10, 20), (30, 40)], 42,
                                                     discarded=[(1, 3)])
        self.assertEqual([row["symbol"] for row in summary["all_threads"]["self"]], ["measured()"])
        self.assertEqual((summary["samples_outside_windows"], summary["samples_other_processes"],
                          summary["samples_in_discarded_windows"]), (2, 1, 1))
        self.assertEqual({row["symbol"] for row in summary["outside_windows_self"]}, {"setup()", "teardown()"})

    def test_empty_profile_or_nothing_in_windows_fails(self) -> None:
        with self.assertRaises(attribution.AttributionError):
            attribution.summarize_time_profile(time_profile([]), None, 42)
        samples = Samples()
        with self.assertRaisesRegex(attribution.AttributionError, "1 outside"):
            attribution.summarize_time_profile(time_profile([samples.row(5, MAIN, [("x", "TronMobile")])]), [(10, 20)], 42)

    def test_schema_changes_fail_instead_of_reading_zero(self) -> None:
        renamed = tuple("backtrace" if column == "stack" else column for column in TIME_PROFILE_COLUMNS)
        samples = Samples()
        with self.assertRaisesRegex(attribution.AttributionError, "schema changed"):
            attribution.summarize_time_profile(attribution.iter_rows(
                result("time-profile", renamed, [samples.row(1, MAIN, [("x", "TronMobile")])])), None, 42)
        with self.assertRaisesRegex(attribution.AttributionError, "schema changed"):
            attribution.signpost_intervals(attribution.iter_rows(
                result("os-signpost-interval", ("start", "name"), ["<row><start-time>1</start-time><string>x</string></row>"])))
        with self.assertRaisesRegex(attribution.AttributionError, "undefined element"):
            attribution.summarize_time_profile(attribution.iter_rows(result("time-profile", TIME_PROFILE_COLUMNS, [
                '<row><sample-time>1</sample-time><thread ref="99"/><process ref="98"/><core>0</core>'
                '<thread-state>Running</thread-state><weight>1</weight><tagged-backtrace ref="97"/></row>'])), None, None)
        with self.assertRaises(attribution.AttributionError):
            list(attribution.iter_rows("<trace-toc/>"))

    def test_retained_memory_does_not_grow_with_references(self) -> None:
        # 2,000 distinct stacks, each 1 new leaf over the same 199 shared
        # frames: 398,000 frame references to 2,199 frame definitions.
        samples = Samples()
        shared = [(f"caller{depth}()", "UIKitCore") for depth in range(199)]
        rows = [samples.row(time, MAIN, [(f"leaf{time}()", "TronMobile"), *shared]) for time in range(2_000)]
        with tempfile.TemporaryDirectory() as directory:
            export = Path(directory) / "time-profile.xml"
            export.write_text(result("time-profile", TIME_PROFILE_COLUMNS, rows))
            del rows
            tracemalloc.start()
            try:
                summary = attribution.summarize_time_profile(attribution.iter_rows(export), None, 42)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
        # Kept per reference, this export peaked at 174 MB (166 MiB); each
        # reference resolved to its shared definition once, 6.9 MB (6.6 MiB).
        self.assertLess(peak, 24 * 1024 * 1024)
        self.assertEqual(summary["samples"], 2_000)
        # Every shared frame, reached only through references, is in every sample.
        total = summary["all_threads"]["total"]
        self.assertEqual(len(total), attribution.TOP_SYMBOLS)
        self.assertTrue(all(row["symbol"].startswith("caller") and row["share"] == 1.0 for row in total))

    def test_recursion_counts_once_toward_total_time(self) -> None:
        samples = Samples()
        rows = [samples.row(1, MAIN, [("layout()", "SwiftUI"), ("layout()", "SwiftUI"), ("main", "TronMobile")])]
        summary = attribution.summarize_time_profile(time_profile(rows), None, 42)
        total = {row["symbol"]: row["share"] for row in summary["all_threads"]["total"]}
        self.assertEqual(total["layout()"], 1.0)

    def test_window_list_must_match_the_measured_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "windows.jsonl"
            path.write_text("".join(f'{{"iteration": {index}, "start": {100 + index}, "end": {100.5 + index}}}\n'
                                    for index in range(1, 4)))
            measured, discarded = attribution.load_windows(path, 2, skip=1)
            self.assertEqual((measured, discarded), ([(102.0, 102.5), (103.0, 103.5)], [(101.0, 101.5)]))
            with self.assertRaisesRegex(attribution.AttributionError, "3 windows; 3 measured iterations need 4"):
                attribution.load_windows(path, 3, skip=1)

    def test_windows_map_onto_the_trace_and_must_lie_inside_it(self) -> None:
        samples = Samples()
        # Two samples: 1.0 s and 3.0 s after the trace start.
        rows = result("time-profile", TIME_PROFILE_COLUMNS, [
            samples.row(1_000_000_000, MAIN, [("before()", "TronMobile")]),
            samples.row(3_000_000_000, MAIN, [("measured()", "TronMobile")]),
        ])
        toc = attribution.ElementTree.fromstring(TOC)
        with mock.patch.object(attribution, "export_toc", return_value=toc), \
                mock.patch.object(attribution, "export_rows", side_effect=lambda *_: attribution.iter_rows(rows)):
            document = attribution.attribute(Path("x.trace"), "time-profiler", 42, [(TOC_EPOCH + 2.5, TOC_EPOCH + 3.5)])
            self.assertEqual([row["symbol"] for row in document["time_profile"]["all_threads"]["self"]], ["measured()"])
            self.assertIsNone(document["signposts"])
            self.assertTrue(any("signposts unavailable" in warning for warning in document["warnings"]))
            with self.assertRaisesRegex(attribution.AttributionError, "starts before the recording"):
                attribution.attribute(Path("x.trace"), "time-profiler", 42, [(TOC_EPOCH - 1, TOC_EPOCH + 3.5)])

    def test_self_test_requires_the_control_workload_in_the_top_self_symbols(self) -> None:
        def document(symbols: list[str]) -> dict:
            return {"time_profile": {"all_threads": {"self": [
                {"symbol": symbol, "share": 0.1, "ms": 10.0} for symbol in symbols]}}}
        passed = profiler.control_attribution_verdict(document(
            ["main", "static ProfileControlRun.controlExtraCPUWorkload(seed:rounds:)"]))
        self.assertTrue(passed[3])
        misplaced = document(["controlExtraCPUWorkload"])
        misplaced["time_profile"]["all_threads"]["self"][0]["ms"] = 100.0
        misplaced["time_profile"]["outside_windows_self"] = [{"symbol": "controlExtraCPUWorkload", "ms": 40.0}]
        self.assertFalse(profiler.control_attribution_verdict(misplaced)[3])
        buried = ["a", "b", "c", "d", "e", "controlExtraCPUWorkload"]
        self.assertFalse(profiler.control_attribution_verdict(document(buried))[3])
        self.assertFalse(profiler.control_attribution_verdict(document(["<unresolved address in TronMobileTests>"]))[3])
        self.assertFalse(profiler.control_attribution_verdict({})[3])


if __name__ == "__main__":
    unittest.main()
