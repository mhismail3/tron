#!/usr/bin/env python3
"""Failure-mode tests for the incident triage tool.

Each case targets one way `scripts/tron-triage` could mislead an operator, one
per cause in the hardening plan's Context plus the joins and the input contract:

1. A relay-path outage attributed to the phone or to the Gateway because the
   Gateway's own silent-socket record was not joined to the episode.
2. A transport-open timeout that never reached the Mac read as a Gateway stall,
   and the successful retry that followed read as that attempt's arrival.
3. "Reconnecting" published over a live socket (the incident's second cause)
   reported as `unknown` or as a real transport loss.
4. A silent recovery gap with no attempt at all (its third cause) dropped from
   the report or attributed to the path.
5. An episode the phone parked in the background attributed to the path, the
   Gateway or the phone's own stall.
6. A slow Gateway span, and a Gateway refusal at a named capacity bound, both
   reported as `unknown`.
7. A protocol-5 export with no correlation key reported as unjoined instead of
   joined by the time window.
8. A phone-only artifact with no Gateway log directory reporting zero Gateway
   records instead of the rows the export carries.
9. A run that writes to one of its inputs.
10. An unreadable line counted as a record, or the run refusing to finish.

`ReviewRegressionTests` covers the shapes a review of the first pass found:
a slow span that ended after the episode, another connection's slow span in a
key-joined episode, the app's real scene records, the settings pool's
second-profile attempt, a request issued before the loss, and one attempt
recorded by both phone shapes.

`ReviewRoundTwoTests` covers the shapes a second review of the real incident
export found: a scene blip splitting a published outage, a slow span on the
socket the reconnect opened, the app-level `operation.gatewayConnect` attempt a
pre-O-4 export writes, the evidence margin, and a Gateway-wide record in the
pad.

The fixtures are small, sanitized records with the real shapes: phone rows are
`AppLogRecord` JSON with details in the message, and Gateway rows are
`gateway.jsonl` records with typed fields. The report of the full run is kept
at `TRON_TRIAGE_TEST_REPORT` (default: a new file under the system temp
directory) so a reviewer can read what the tool produced.
"""

from __future__ import annotations

import json
import os
from datetime import timedelta
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
FRONT_DOOR = ROOT / "scripts/tron-triage"
MODULE = ROOT / "scripts/tron_triage.py"
sys.path.insert(0, str(ROOT / "scripts"))

import tron_triage  # noqa: E402  (the module under test, imported by path)

REPORT_KEEPS = 3


def app_record(timestamp, event, message, level="info", outcome=None, duration_ms=None,
               profile_id=None, connection_id=None, lifecycle_generation=7, source="app"):
    record = {
        "timestamp": timestamp, "level": level, "event": event, "source": source,
        "message": (f"outcome={outcome} " if outcome is not None else "") + message,
        "process": "ios",
    }
    if duration_ms is not None:
        record["durationMs"] = duration_ms
    if outcome is not None:
        record["outcome"] = outcome
    if profile_id is not None:
        record["profileID"] = profile_id
    if connection_id is not None:
        record["connectionID"] = connection_id
    if lifecycle_generation is not None:
        record["lifecycleGeneration"] = lifecycle_generation
    return record


def local_compact(instant):
    """A `log show --style compact` timestamp for a UTC instant, in local time."""
    parsed = tron_triage.parse_timestamp(instant)
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M:%S.%f")


def gateway_record(timestamp, event, level, message, **fields):
    record = {
        "timestamp": timestamp, "level": level, "message": message, "process": "gateway",
        "event": event, "source": "transport",
    }
    record.update(fields)
    return record


def attempt(timestamp, duration_ms, outcome, stage, reason, gateway_connection_id=None,
            foreground=True, attempt_id="initial", profile_id="p1", client_id=None):
    message = (
        f"profile={profile_id} attemptId={attempt_id} retry=0 stageReached={stage} "
        f"reason={reason} interfaces=unknown pathSatisfied=true delayBeforeMs=0 "
        f"foreground={'true' if foreground else 'false'} "
        f"gatewayConnectionId={gateway_connection_id or 'none'}"
    )
    if client_id is not None:
        message += f" clientId={client_id}"
    return app_record(timestamp, "gateway.attempt", message, level="info", outcome=outcome,
                      duration_ms=duration_ms, profile_id=profile_id)


def episode(started_at, ended_at, attempts, causes, ended_by, profile_id="p1"):
    return app_record(
        ended_at, "connection.episode",
        f"profile={profile_id} startedAt={started_at} endedAt={ended_at} attempts={attempts} "
        f"causes={causes} foregroundMs=5000 maxGapBetweenAttemptsMs=1000 endedBy={ended_by}",
        level="info", outcome=ended_by, duration_ms=5000, profile_id=profile_id,
    )


def state_change(timestamp, old, new):
    return app_record(timestamp, "connection.state-changed",
                      f"old={old} new={new} gatewayEpoch=epoch-1",
                      level="info", outcome=new, source="app", lifecycle_generation=None)


class TriageFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tron-triage-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.logs = self.root / "logs"
        self.logs.mkdir()

    def write(self, name, records):
        path = self.root / name
        path.write_text("".join(json.dumps(record) + "\n" for record in records),
                        encoding="utf-8")
        return path

    def gateway(self, records, name="gateway.jsonl"):
        return self.write(f"logs/{name}", records)

    def run_tool(self, export, extra=(), gateway_logs=None, json_output=True):
        arguments = [sys.executable, str(MODULE), str(export),
                     "--gateway-logs", str(gateway_logs or self.logs)]
        if json_output:
            arguments.append("--json")
        arguments.extend(extra)
        completed = subprocess.run(arguments, capture_output=True, text=True, timeout=120)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout) if json_output else completed.stdout

    def log_show(self, text, returncode=0):
        """A fixture `log` executable, so no test hook lives in the tool."""
        path = self.root / "fake-log"
        path.write_text("#!/bin/sh\n"
                        f"printf '%s' {shlex.quote(text)}\n"
                        f"exit {returncode}\n", encoding="utf-8")
        path.chmod(0o755)
        previous = tron_triage.TAILSCALE_LOG_TOOL
        tron_triage.TAILSCALE_LOG_TOOL = str(path)
        self.addCleanup(setattr, tron_triage, "TAILSCALE_LOG_TOOL", previous)
        return path

    def only_episode(self, report):
        self.assertEqual(report["summary"]["episodes"], 1, report["episodes"])
        return report["episodes"][0]

    def causes_text(self, episode):
        return " | ".join(entry["detail"] for entry in episode["evidence"])


class PathOutageTests(TriageFixture):
    """Cause 1: a Tailscale flap, seen as silence on an open socket."""

    def test_relay_silence_joined_by_key_is_the_path(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T01:29:59.000Z", 36, "success", "connected", "none",
                    gateway_connection_id="gw-1"),
            attempt("2026-09-28T01:30:05.000Z", 5042, "failure", "hello-receive", "transport"),
            attempt("2026-09-28T01:31:28.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-1"),
            episode("2026-09-28T01:30:00.000Z", "2026-09-28T01:31:28.000Z", 2,
                    "pong_timeout,transport", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T01:29:59.000Z", "connection.opened", "info",
                           "Client gw-1 connection opened (paired, mobile role) after 9ms",
                           connectionId="gw-1", peerClientId="c1", peerAttemptId="initial",
                           peerEpoch="1"),
            gateway_record("2026-09-28T01:30:20.000Z", "connection.inbound-silent", "warning",
                           "Client gw-1 has sent nothing for 21000ms (unansweredPingMs=none)",
                           connectionId="gw-1", peerClientId="c1", peerAttemptId="initial",
                           peerEpoch="1", peerPath="relay", peerRelay="sfo"),
            gateway_record("2026-09-28T01:31:28.000Z", "connection.inbound-resumed", "info",
                           "Client gw-1 inbound resumed after 68000ms of silence",
                           connectionId="gw-1", peerClientId="c1", peerAttemptId="initial",
                           peerEpoch="1", silentMs=68000),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "path")
        self.assertEqual(found["joinedBy"], "key")
        self.assertIn("peerPath=relay", self.causes_text(found))
        self.assertIn("peerRelay=sfo", self.causes_text(found))
        self.assertIn("silentMs=68000", self.causes_text(found))

    def test_transport_open_timeout_that_never_reached_the_mac_is_the_path(self):
        phone = self.write("phone.jsonl", [
            # The attempt failed at its own 15 s deadline; the retry that followed
            # connected, and its gatewayConnectionId is a different socket.
            attempt("2026-09-28T01:35:00.000Z", 15000, "failure", "transport-open", "timeout",
                    attempt_id="a1"),
            attempt("2026-09-28T01:35:04.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-2", attempt_id="a1"),
            episode("2026-09-28T01:34:55.000Z", "2026-09-28T01:35:04.000Z", 2, "transport",
                    "connected"),
        ])
        self.gateway([
            # Another client's socket in the same window must not be read as this
            # attempt's arrival.
            gateway_record("2026-09-28T01:34:58.000Z", "connection.opened", "info",
                           "Client gw-other connection opened after 9ms",
                           connectionId="gw-other", peerClientId="other", peerAttemptId="initial"),
            gateway_record("2026-09-28T01:35:04.000Z", "connection.opened", "info",
                           "Client gw-2 connection opened after 12ms", connectionId="gw-2",
                           peerClientId="c2", peerAttemptId="a1"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "path")
        self.assertIn("transport-open timeout of 15000ms with no Gateway accept",
                      self.causes_text(found))


class PhoneStallTests(TriageFixture):
    """Causes 2 and 3: a wrong label over a live socket, and a silent gap."""

    def test_reconnecting_label_over_a_live_socket_is_a_phone_stall(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T04:04:59.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-3"),
            state_change("2026-09-28T04:05:25.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T04:11:46.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T04:04:59.000Z", "connection.opened", "info",
                           "Client gw-3 connection opened after 9ms", connectionId="gw-3",
                           peerClientId="c3", peerAttemptId="initial"),
            gateway_record("2026-09-28T04:06:00.000Z", "rpc.completed", "debug",
                           "RPC session.open for client gw-3 completed in 800ms (success)",
                           method="session.open", connectionId="gw-3", outcome="success",
                           durationMs=800),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "phone-stall")
        self.assertTrue(found["derived"])
        self.assertIn("published state stayed reconnecting", self.causes_text(found))

    def test_a_closed_socket_is_not_a_wrong_label(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T04:04:59.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-3"),
            state_change("2026-09-28T04:05:25.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T04:11:46.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T04:04:59.000Z", "connection.opened", "info",
                           "Client gw-3 connection opened after 9ms", connectionId="gw-3"),
            gateway_record("2026-09-28T04:05:10.000Z", "connection.closed", "info",
                           "Client gw-3 connection closed after 11000ms", connectionId="gw-3",
                           durationMs=11000),
            gateway_record("2026-09-28T04:06:00.000Z", "rpc.completed", "debug",
                           "RPC session.open for client gw-3 completed in 800ms (success)",
                           method="session.open", connectionId="gw-3", outcome="success",
                           durationMs=800),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "unknown")

    def test_silent_gap_with_no_attempt_is_reported_as_unknown(self):
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T03:24:00.000Z", "scene.foreground", "sceneAt=2026-09-28T03:24:00.000Z from=background"),
            app_record("2026-09-28T03:24:00.100Z", "scene.active", "sceneAt=2026-09-28T03:24:00.100Z from=background"),
            state_change("2026-09-28T03:24:45.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T03:30:30.000Z", "reconnecting", "connected"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "unknown")
        self.assertEqual(found["attempts"], 0)
        self.assertEqual(found["durationMs"], 345000)
        self.assertIn("no attempt recorded in this window (gap of 345s)",
                      self.causes_text(found))
        self.assertEqual(found["joinedBy"], "none")

    def test_recorded_stall_watchdog_is_a_phone_stall(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T03:40:00.000Z", "connected", "reconnecting"),
            app_record("2026-09-28T03:40:25.000Z", "reconnect.stalled",
                       "guard=pathUnsatisfied heldForMs=20000 silentForMs=25000 attempts=0 "
                       "foreground=true boundMs=20000",
                       level="error", outcome="stalled", duration_ms=20000),
            state_change("2026-09-28T03:41:00.000Z", "reconnecting", "connected"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "phone-stall")
        self.assertIn("guard=pathUnsatisfied", self.causes_text(found))


class BackgroundTests(TriageFixture):
    """Cause 1's trap: a backgrounded phone's timeouts are not path faults."""

    def test_background_parked_episode_is_not_the_path(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T02:00:00.000Z", "connected", "reconnecting"),
            attempt("2026-09-28T02:00:05.000Z", 15000, "failure", "transport-open", "background",
                    foreground=False),
            episode("2026-09-28T02:00:00.000Z", "2026-09-28T02:00:30.000Z", 1, "background",
                    "background"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "phone-background")
        self.assertIn("endedBy=background", self.causes_text(found))

    def test_a_gap_after_a_background_episode_is_its_own_episode(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T02:00:00.000Z", "connected", "reconnecting"),
            episode("2026-09-28T02:00:00.000Z", "2026-09-28T02:00:30.000Z", 1, "background",
                    "background"),
            app_record("2026-09-28T02:00:30.000Z", "scene.background",
                       "sceneAt=2026-09-28T02:00:30.000Z from=active"),
            app_record("2026-09-28T02:15:00.000Z", "scene.foreground",
                       "sceneAt=2026-09-28T02:15:00.000Z from=background"),
            state_change("2026-09-28T02:15:01.000Z", "connected", "connecting"),
            state_change("2026-09-28T02:15:05.000Z", "connecting", "reconnecting"),
            state_change("2026-09-28T02:17:00.000Z", "reconnecting", "connected"),
        ])
        report = self.run_tool(phone)
        self.assertEqual(report["summary"]["episodes"], 2, report["episodes"])
        self.assertEqual([item["cause"] for item in report["episodes"]],
                         ["phone-background", "unknown"])
        self.assertEqual(report["episodes"][1]["start"], "2026-09-28T02:15:05.000Z")

    def test_scene_background_at_the_end_splits_the_episode(self):
        # Review round 2, finding 1: the app was in the foreground for the whole
        # first stretch, so the scene record that ends it (where the app left
        # the foreground) cannot make that stretch a background episode. Only
        # the time really spent in the background is `phone-background`.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T02:10:00.000Z", "connected", "reconnecting"),
            app_record("2026-09-28T02:10:20.000Z", "scene.background",
                       "sceneAt=2026-09-28T02:10:20.000Z from=active"),
            state_change("2026-09-28T02:12:00.000Z", "reconnecting", "connected"),
        ])
        report = self.run_tool(phone)
        self.assertEqual([item["cause"] for item in report["episodes"]],
                         ["unknown", "phone-background"], report["episodes"])
        foreground, background = report["episodes"]
        self.assertEqual(foreground["start"], "2026-09-28T02:10:00.000Z")
        self.assertEqual(foreground["end"], "2026-09-28T02:10:20.000Z")
        self.assertIn("scene.background",
                      " ".join(entry["event"] for entry in background["evidence"]))


class GatewayTests(TriageFixture):
    """Cause 4 plus capacity: the Gateway's own records name its cause."""

    def test_slow_span_and_event_loop_delay_are_a_gateway_stall(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T06:00:00.000Z", 36, "success", "connected", "none",
                    gateway_connection_id="gw-4"),
            attempt("2026-09-28T06:00:20.000Z", 5042, "failure", "hello-receive", "transport"),
            attempt("2026-09-28T06:01:00.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-4"),
            episode("2026-09-28T06:00:10.000Z", "2026-09-28T06:01:00.000Z", 2, "transport",
                    "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T06:00:00.000Z", "connection.opened", "info",
                           "Client gw-4 connection opened after 9ms", connectionId="gw-4",
                           peerClientId="c4", peerAttemptId="initial"),
            gateway_record("2026-09-28T06:00:30.000Z", "gateway.event-loop-delay", "warning",
                           "Heartbeat arrived 2400ms late", durationMs=2400),
            gateway_record("2026-09-28T06:00:40.000Z", "rpc.completed", "warning",
                           "RPC session.open for client gw-4 completed in 52400ms (success)",
                           method="session.open", connectionId="gw-4", outcome="success",
                           durationMs=52400, stages="catalog.walk=30000ms;open=20000ms"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "gateway-stall")
        text = self.causes_text(found)
        self.assertIn("durationMs=52400", text)
        self.assertIn("gateway.event-loop-delay", " ".join(
            entry["event"] for entry in found["evidence"]))

    def test_capacity_refusal_is_gateway_capacity(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T07:00:05.000Z", 5042, "failure", "hello-receive", "transport"),
            attempt("2026-09-28T07:00:20.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-5"),
            episode("2026-09-28T07:00:00.000Z", "2026-09-28T07:00:20.000Z", 2, "transport",
                    "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T07:00:02.000Z", "connection.capacity", "warning",
                           "Connection capacity 16/16 for identity c5",
                           connectionId="gw-5", peerClientId="c5"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "gateway-capacity")
        self.assertIn("Connection capacity 16/16", self.causes_text(found))


class JoinTests(TriageFixture):
    """A protocol-5 export, and a phone-only artifact."""

    def test_protocol_five_export_joins_by_time_window(self):
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T05:00:00.000Z", "gateway.connection",
                       "stage=transport-open outcome=failure sequence=1 clientID=c9 "
                       "attemptID=a1 durationMs=15000 recordKind=connection reason=timeout",
                       level="warning", outcome="failure", duration_ms=15000),
            app_record("2026-09-28T05:00:20.000Z", "gateway.connection",
                       "stage=hello-receive outcome=success sequence=2 clientID=c9 "
                       "attemptID=a1 durationMs=300 recordKind=connection",
                       level="info", outcome="success", duration_ms=300),
            state_change("2026-09-28T04:59:58.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T05:00:21.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            # A pre-O-1 Gateway writes no peer key, so only time joins the two.
            gateway_record("2026-09-28T05:00:15.000Z", "connection.opened", "info",
                           "Client gw-9 connection opened (paired, mobile role) after 9ms",
                           connectionId="gw-9"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["joinedBy"], "window")
        self.assertEqual(found["cause"], "path")
        self.assertIn("transport-open timeout of 15000ms with no Gateway accept",
                      self.causes_text(found))

    def test_phone_only_artifact_uses_the_rows_the_export_carries(self):
        export = self.write("phone.jsonl", [
            app_record("2026-09-28T08:00:00.000Z", "diagnostics.exported",
                       "copiedAt=2026-09-28T08:10:00.000Z loadedAt=2026-09-28T08:09:59.000Z "
                       "representedFrom=2026-09-28T07:00:00.000Z "
                       "representedThrough=2026-09-28T08:09:59.000Z appBuild=1+2 "
                       "source-1.status=fresh-remote",
                       level="info", lifecycle_generation=None),
            attempt("2026-09-28T08:00:05.000Z", 5042, "failure", "hello-receive", "transport"),
            attempt("2026-09-28T08:00:20.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-6"),
            episode("2026-09-28T08:00:00.000Z", "2026-09-28T08:00:20.000Z", 2, "transport",
                    "connected"),
            # The phone-app export writes the Mac's rows as `AppLogRecord` with
            # `connectionID` null, so its own Gateway rows carry no key and only
            # the time window can join them.
            dict(gateway_record("2026-09-28T08:00:10.000Z", "connection.opened", "info",
                                "Client gw-6 connection opened after 9ms"),
                 process="gateway", profileID=None, connectionID=None,
                 lifecycleGeneration=None),
        ])
        report = self.run_tool(export, extra=["--no-gateway-logs"])
        self.assertEqual(report["inputs"]["gatewayLogs"]["source"], "export-projection")
        self.assertEqual(report["inputs"]["gatewayLogs"]["records"], 1)
        self.assertEqual(report["inputs"]["phoneExports"][0]["capture"]["appBuild"], "1+2")
        self.assertEqual(report["episodes"][0]["joinedBy"], "window")


class InputContractTests(TriageFixture):
    """The tool reads its inputs and writes only its own report."""

    def test_a_run_does_not_modify_its_inputs(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T09:00:00.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-7"),
        ])
        logs = self.gateway([
            gateway_record("2026-09-28T09:00:00.000Z", "connection.opened", "info",
                           "Client gw-7 connection opened after 9ms", connectionId="gw-7"),
        ])
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in (phone, logs)}
        report = self.run_tool(phone)
        self.assertEqual(report["summary"]["phoneRecords"], 1)
        for path, (content, mtime) in before.items():
            self.assertEqual(path.read_bytes(), content, path)
            self.assertEqual(path.stat().st_mtime_ns, mtime, path)

    def test_an_unreadable_line_is_counted_and_the_run_finishes(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T09:30:00.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-8"),
        ])
        with phone.open("a", encoding="utf-8") as handle:
            handle.write("{not json\n")
        report = self.run_tool(phone)
        self.assertEqual(report["inputs"]["phoneExports"][0]["unreadableLines"], 1)

    def test_the_report_output_refuses_to_overwrite_an_input(self):
        phone = self.write("phone.jsonl", [attempt("2026-09-28T09:40:00.000Z", 38, "success",
                                                   "connected", "none")])
        completed = subprocess.run(
            [sys.executable, str(MODULE), str(phone), "--json", "--out", str(phone)],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("refusing to overwrite", completed.stderr)
        self.assertTrue(phone.read_text(encoding="utf-8").startswith("{"))

    def test_a_missing_export_is_refused(self):
        completed = subprocess.run(
            [sys.executable, str(MODULE), str(self.root / "absent.jsonl")],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("no such phone export", completed.stderr)


class TailscaleWindowTests(TriageFixture):
    """The extension log is the only path evidence a pre-O-2 Gateway log leaves.

    The lines are the real Magicsock forms, printed in the compact style whose
    timestamps carry no UTC offset.
    """

    def magicsock_lines(self, relay_at, direct_at, peer="6wPGm"):
        return (
            "Timestamp               Ty Process[PID:TID]\n"
            f"{local_compact(relay_at)} Df io.tailscale.ipn.macsys.network-extension[3443:48f6] "
            f"magicsock: new contact: peer=[{peer}] usec=399978702823 cached=false via=derp\n"
            f"{local_compact(direct_at)} Df io.tailscale.ipn.macsys.network-extension[3443:4954] "
            f"magicsock: disco: node [{peer}] d:8767 now using 192.0.2.23:41641 mtu=1360 tx=abc\n"
        )

    def test_relay_lines_become_a_relay_window(self):
        self.log_show(self.magicsock_lines("2026-09-27T22:10:00.000Z", "2026-09-27T22:20:00.000Z"))
        start = tron_triage.parse_timestamp("2026-09-27T20:00:00.000Z")
        capture = tron_triage.capture_tailscale_window(start, start.replace(hour=23))
        self.assertTrue(capture.captured, capture.reason)
        windows = capture.relay_windows()
        self.assertEqual(len(windows), 1, capture.lines)
        self.assertEqual(windows[0][2], "relay")
        self.assertLess(windows[0][0], windows[0][1])
        self.assertEqual(
            windows[0][0], tron_triage.parse_timestamp("2026-09-27T22:10:00.000Z"))

    def test_a_peer_filter_keeps_another_peers_relay_out(self):
        text = self.magicsock_lines("2026-09-27T22:10:00.000Z", "2026-09-27T22:20:00.000Z",
                                    peer="other")
        self.log_show(text)
        start = tron_triage.parse_timestamp("2026-09-27T20:00:00.000Z")
        capture = tron_triage.capture_tailscale_window(start, start.replace(hour=23), "6wPGm")
        self.assertTrue(capture.captured, capture.reason)
        self.assertEqual(capture.lines, [])

    def test_relay_window_classifies_a_path_episode(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T10:00:00.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T10:01:30.000Z", "reconnecting", "connected"),
        ])
        self.log_show(self.magicsock_lines("2026-09-28T09:59:00.000Z", "2026-09-28T10:05:00.000Z"))
        report = tron_triage.triage_reports([phone], None, 60, True)
        self.assertEqual(report["inputs"]["tailscaleWindow"]["captured"], True)
        self.assertEqual(report["episodes"][0]["cause"], "path")
        self.assertIn("relay path window", " ".join(
            entry["detail"] for entry in report["episodes"][0]["evidence"]))

    def test_a_failing_log_show_does_not_stop_the_run(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T10:00:00.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T10:01:30.000Z", "reconnecting", "connected"),
        ])
        self.log_show("", returncode=3)
        report = tron_triage.triage_reports([phone], None, 60, True)
        self.assertEqual(report["inputs"]["tailscaleWindow"]["captured"], False)
        self.assertEqual(report["episodes"][0]["cause"], "unknown")


class ReviewRegressionTests(TriageFixture):
    """The failure modes an independent review found on the branch.

    Each one is a shape the real device exports and the real `log show`
    produce, not the fixture shape the first pass invented.
    """

    def test_a_slow_span_that_ended_after_the_episode_is_not_its_cause(self):
        # The 2026-09-28 export: a 0.2 s reconnect right after the app
        # foregrounds, whose own refresh RPCs complete seconds later. The
        # Gateway answering a later request does not explain the reconnect.
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T06:35:59.422Z", "app.foregrounded", "outcome=success"),
            state_change("2026-09-28T06:35:59.436Z", "connected", "reconnecting"),
            state_change("2026-09-28T06:35:59.604Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T06:36:03.966Z", "rpc.completed", "warning",
                           "RPC session.list for client 16e59486 completed in 4200ms (success)",
                           method="session.list", connectionId="16e59486", outcome="success",
                           durationMs=4200),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "unknown", found["evidence"])

    def test_another_connections_slow_span_is_not_this_episodes_cause(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T11:00:00.000Z", 36, "success", "connected", "none",
                    gateway_connection_id="gw-A"),
            state_change("2026-09-28T11:00:10.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T11:00:11.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T11:00:00.000Z", "connection.opened", "info",
                           "Client gw-A connection opened after 9ms", connectionId="gw-A",
                           peerClientId="cA", peerAttemptId="initial"),
            gateway_record("2026-09-28T11:00:21.000Z", "rpc.completed", "warning",
                           "RPC session.list for client mac-1 completed in 3000ms (success)",
                           method="session.list", connectionId="mac-1", outcome="success",
                           durationMs=3000),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["joinedBy"], "key")
        self.assertNotEqual(found["cause"], "gateway-stall", found["evidence"])

    def test_app_scene_records_are_recognised(self):
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T07:21:02.478Z", "app.backgrounded", "outcome=success"),
            app_record("2026-09-28T07:21:02.705Z", "app.foregrounded", "outcome=success"),
            state_change("2026-09-28T07:21:02.714Z", "connected", "reconnecting"),
            state_change("2026-09-28T07:21:02.799Z", "reconnecting", "connected"),
            state_change("2026-09-28T07:21:02.804Z", "connected", "reconnecting"),
            app_record("2026-09-28T07:24:10.754Z", "app.backgrounded", "outcome=success"),
            state_change("2026-09-28T07:24:12.401Z", "unpaired", "connecting"),
            state_change("2026-09-28T07:24:12.568Z", "connecting", "connected"),
        ])
        report = self.run_tool(phone)
        causes = [episode["cause"] for episode in report["episodes"]]
        # The 187 s stretch the last `app.backgrounded` closes was foreground
        # until that record, so it is a silent gap, and only the 1.6 s after the
        # record is `phone-background` (review round 2, finding 1).
        self.assertEqual(len(causes), 3, report["episodes"])
        self.assertEqual(causes, ["unknown", "unknown", "phone-background"], report["episodes"])
        self.assertEqual(report["episodes"][1]["durationMs"], 187950)
        self.assertEqual(report["episodes"][2]["durationMs"], 1647)

    def test_retained_client_scene_kind_splits_the_episode(self):
        # The retained client log writes the same transition as
        # `gateway.lifecycle kind=scene.*`; both phases have to be read, or the
        # background stretch is misreported as foreground time.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T09:00:01.000Z", "connected", "reconnecting"),
            app_record("2026-09-28T09:00:30.000Z", "gateway.lifecycle",
                       "kind=scene.background clientID=cX scene=background"),
            app_record("2026-09-28T09:00:40.000Z", "gateway.lifecycle",
                       "kind=scene.foreground clientID=cX scene=foreground"),
            state_change("2026-09-28T09:01:00.000Z", "reconnecting", "connected"),
        ])
        report = self.run_tool(phone)
        self.assertEqual([item["cause"] for item in report["episodes"]],
                         ["unknown", "phone-background", "unknown"], report["episodes"])
        self.assertEqual(report["episodes"][1]["start"], "2026-09-28T09:00:30.000Z")
        self.assertEqual(report["episodes"][1]["end"], "2026-09-28T09:00:40.000Z")

    def test_another_profiles_failed_attempt_is_not_this_episodes_path(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T12:00:01.000Z", 15000, "failure", "transport-open", "timeout",
                    attempt_id="pool-loop", profile_id="pool-secondary"),
            episode("2026-09-28T12:00:00.000Z", "2026-09-28T12:00:20.000Z", 1, "transport",
                    "connected", profile_id="mobile-prod"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["profile"], "mobile-prod")
        self.assertNotEqual(found["cause"], "path", found["evidence"])

    def test_the_episodes_own_failed_attempt_is_still_the_path(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T12:30:01.000Z", 15000, "failure", "transport-open", "timeout",
                    attempt_id="own-loop", profile_id="mobile-prod"),
            episode("2026-09-28T12:30:00.000Z", "2026-09-28T12:30:20.000Z", 1, "transport",
                    "connected", profile_id="mobile-prod"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "path", found["evidence"])

    def test_a_request_issued_before_the_loss_is_not_a_wrong_label(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T13:00:00.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-L"),
            state_change("2026-09-28T13:00:15.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T13:00:20.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T13:00:00.000Z", "connection.opened", "info",
                           "Client gw-L connection opened after 9ms", connectionId="gw-L"),
            gateway_record("2026-09-28T13:00:20.000Z", "rpc.completed", "debug",
                           "RPC session.list for client gw-L completed in 20000ms (success)",
                           method="session.list", connectionId="gw-L", outcome="success",
                           durationMs=20000),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertNotEqual(found["cause"], "phone-stall", found["evidence"])

    def test_one_attempt_is_counted_once_when_both_shapes_are_written(self):
        rows = []
        for index, loop in enumerate(("loop-1", "loop-1", "loop-2", "loop-2")):
            rows.append(attempt(f"2026-09-28T15:00:{index:02d}.000Z", 15000, "failure",
                                "transport-open", "timeout", attempt_id=loop,
                                profile_id="mobile-prod"))
            rows.append(app_record(
                f"2026-09-28T15:00:{index:02d}.000Z", "gateway.connection",
                f"stage=transport-open outcome=failure sequence={index} clientID=c1 "
                f"attemptID={loop} durationMs=15000 recordKind=connection reason=timeout",
                level="warning", outcome="failure", duration_ms=15000))
        phone = self.write("phone.jsonl", rows)
        records, _ = tron_triage.read_jsonl(phone)
        self.assertEqual(len(tron_triage.phone_attempts(records)), 4)

    def test_retries_sharing_a_loop_id_survive_without_attempt_records(self):
        rows = [app_record(f"2026-09-28T15:30:{index:02d}.000Z", "gateway.connection",
                           f"stage=transport-open outcome=failure sequence={index} clientID=c1 "
                           f"attemptID=loop-1 durationMs=15000 recordKind=connection reason=timeout",
                           level="warning", outcome="failure", duration_ms=15000)
                for index in range(3)]
        phone = self.write("phone.jsonl", rows)
        records, _ = tron_triage.read_jsonl(phone)
        self.assertEqual(len(tron_triage.phone_attempts(records)), 3)

    def test_a_retry_accept_past_the_deadline_is_not_this_attempts_arrival(self):
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T14:00:15.000Z", "gateway.attempt",
                       "outcome=failure stageReached=transport-open reason=timeout durationMs=15000",
                       level="warning", outcome="failure", duration_ms=15000),
        ])
        self.gateway([
            gateway_record("2026-09-28T14:00:16.000Z", "connection.opened", "info",
                           "Client gw-R connection opened after 9ms", connectionId="gw-R"),
        ])
        records, _ = tron_triage.read_jsonl(phone)
        attempts = tron_triage.phone_attempts(records)
        gateway = tron_triage.GatewayIndex(records=tron_triage.load_gateway_logs(self.logs).records)
        self.assertFalse(tron_triage.attempt_reached_mac(
            attempts[0], gateway.window(*attempts[0].span())))


class ReviewRoundTwoTests(TriageFixture):
    """The shapes review round 2 found on the real incident export.

    The fixtures are the incident's own record sequences (timestamps, messages
    and durations), reduced to the records each finding needs, so a fixture
    cannot pass by inventing a shape the export does not write.
    """

    def test_a_background_blip_does_not_hide_the_silent_gap_after_it(self):
        # 2026-09-28 03:24: the state is published once at the loss, a 1.4 s
        # background blip interrupts recovery, and the app publishes nothing on
        # the way back to the foreground. The measured silent gap is the stretch
        # between the blip and the next `app.backgrounded`.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T03:24:31.488Z", "connected", "reconnecting"),
            app_record("2026-09-28T03:24:43.600Z", "app.backgrounded", "outcome=success"),
            app_record("2026-09-28T03:24:45.005Z", "app.foregrounded", "outcome=success"),
            app_record("2026-09-28T03:30:30.618Z", "app.backgrounded", "outcome=success"),
            app_record("2026-09-28T03:30:31.402Z", "app.foregrounded", "outcome=success"),
            state_change("2026-09-28T03:30:33.621Z", "reconnecting", "connected"),
        ])
        report = self.run_tool(phone)
        self.assertEqual(
            [episode["cause"] for episode in report["episodes"]],
            ["unknown", "phone-background", "unknown", "phone-background", "unknown"],
            report["episodes"])
        gap = report["episodes"][2]
        self.assertEqual(gap["start"], "2026-09-28T03:24:45.005Z")
        self.assertEqual(gap["end"], "2026-09-28T03:30:30.618Z")
        self.assertEqual(gap["durationMs"], 345613)
        self.assertEqual(gap["attempts"], 0)
        self.assertIn("no attempt recorded in this window (gap of 345s)",
                      self.causes_text(gap))
        # The stretch before the blip was foreground, so it is not the parked
        # episode the scene record that ended it would have made it.
        self.assertEqual(report["episodes"][0]["durationMs"], 12112)
        self.assertIn("no attempt recorded", self.causes_text(report["episodes"][0]))

    def test_a_blip_does_not_stop_the_live_socket_from_being_the_cause(self):
        # 2026-09-28 04:05:25-04:11:46, the incident's second cause. Socket
        # de22b6dd opened 30 ms before the label was published and kept
        # answering; a 4.4 s background blip at 04:10:44 splits the label, and
        # the app restarts at 04:11:46.
        phone = self.write("phone.jsonl", [
            app_record("2026-09-28T04:05:25.790Z", "app.foregrounded", "outcome=success"),
            state_change("2026-09-28T04:05:25.843Z", "connected", "reconnecting"),
            app_record("2026-09-28T04:10:44.428Z", "app.backgrounded", "outcome=success"),
            app_record("2026-09-28T04:10:48.871Z", "app.foregrounded", "outcome=success"),
            app_record("2026-09-28T04:11:46.389Z", "app.started",
                       "appVersion=0.1.0 build=7", lifecycle_generation=None),
            state_change("2026-09-28T04:11:46.402Z", "unpaired", "connecting"),
            state_change("2026-09-28T04:11:46.529Z", "connecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T04:05:25.813Z", "connection.opened", "info",
                           "Client de22b6dd connection opened (paired, mobile role, "
                           "compression=permessage-deflate) after 12ms",
                           connectionId="de22b6dd"),
            gateway_record("2026-09-28T04:05:30.358Z", "rpc.completed", "warning",
                           "RPC session.list for client de22b6dd completed in 4513ms (success)",
                           method="session.list", connectionId="de22b6dd",
                           outcome="success", durationMs=4513),
            gateway_record("2026-09-28T04:10:51.326Z", "rpc.completed", "warning",
                           "RPC push.registration.upsert for client de22b6dd completed in "
                           "2199ms (success)", method="push.registration.upsert",
                           connectionId="de22b6dd", outcome="success", durationMs=2199),
            gateway_record("2026-09-28T04:11:45.392Z", "connection.closed", "info",
                           "Client de22b6dd connection closed after 379585ms",
                           connectionId="de22b6dd"),
        ])
        report = self.run_tool(phone)
        self.assertEqual([episode["cause"] for episode in report["episodes"]],
                         ["phone-stall", "phone-background", "phone-stall"],
                         report["episodes"])
        self.assertEqual(report["episodes"][0]["start"], "2026-09-28T04:05:25.843Z")
        self.assertEqual(report["episodes"][0]["end"], "2026-09-28T04:10:44.428Z")
        self.assertEqual(report["episodes"][2]["end"], "2026-09-28T04:11:46.402Z")
        self.assertIn("published state stayed reconnecting",
                      self.causes_text(report["episodes"][2]))

    def test_the_socket_the_reconnect_opened_is_not_the_cause(self):
        # 2026-09-27 23:59:39: a 76 ms reconnect. The socket it opened 38 ms in
        # began a 4,276 ms `session.list` 6 ms before the episode ended.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-27T23:59:39.590Z", "connected", "reconnecting"),
            state_change("2026-09-27T23:59:39.666Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-27T23:59:39.628Z", "connection.opened", "info",
                           "Client faeb7be1 connection opened (paired, mobile role) after 12ms",
                           connectionId="faeb7be1", peerClientId="c1", peerAttemptId="initial"),
            gateway_record("2026-09-27T23:59:43.936Z", "rpc.completed", "warning",
                           "RPC session.list for client faeb7be1 completed in 4276ms (success)",
                           method="session.list", connectionId="faeb7be1",
                           outcome="success", durationMs=4276),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertNotEqual(found["cause"], "gateway-stall", found["evidence"])
        self.assertEqual(found["cause"], "unknown", found["evidence"])

    def test_a_slow_span_that_began_after_the_loss_is_not_the_cause(self):
        # "The Gateway accepts then stalls `session.open`" is a C-1 failure
        # mode, but the phone's reconnect issues that open itself: a span that
        # began after the loss is the recovery's work, not the outage's cause.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T05:26:45.138Z", "connected", "reconnecting"),
            state_change("2026-09-28T05:26:45.303Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T05:26:40.000Z", "connection.opened", "info",
                           "Client 8435c3e3 connection opened after 9ms",
                           connectionId="8435c3e3"),
            gateway_record("2026-09-28T05:26:52.554Z", "rpc.completed", "warning",
                           "RPC session.list for client 8435c3e3 completed in 7390ms (success)",
                           method="session.list", connectionId="8435c3e3",
                           outcome="success", durationMs=7390),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "unknown", found["evidence"])

    def test_the_episodes_key_is_the_connection_it_lost(self):
        # The record at the end names the socket the reconnect opened; the key
        # of the episode is the connection the failed attempt lost.
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T11:00:05.000Z", 15000, "failure", "transport-open", "timeout",
                    gateway_connection_id="gw-old", attempt_id="a1", profile_id="p1"),
            attempt("2026-09-28T11:00:20.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-new", attempt_id="a1", profile_id="p1"),
            episode("2026-09-28T11:00:00.000Z", "2026-09-28T11:00:20.000Z", 2, "transport",
                    "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T10:59:00.000Z", "connection.opened", "info",
                           "Client gw-old connection opened after 9ms", connectionId="gw-old"),
            gateway_record("2026-09-28T11:00:00.500Z", "connection.closed", "info",
                           "Client gw-old connection closed after 60000ms", connectionId="gw-old"),
            gateway_record("2026-09-28T11:00:19.900Z", "connection.opened", "info",
                           "Client gw-new connection opened after 9ms", connectionId="gw-new"),
        ])
        records, _ = tron_triage.read_jsonl(phone)
        gateway = tron_triage.GatewayIndex(
            records=tron_triage.load_gateway_logs(self.logs).records)
        episodes = tron_triage.build_episodes(records, gateway, timedelta(seconds=60))
        self.assertEqual(len(episodes), 1, episodes)
        self.assertEqual(episodes[0].gateway_ids, {"gw-old"}, episodes[0].gateway_ids)
        tron_triage.classify(episodes[0], gateway, timedelta(seconds=60), None)
        self.assertEqual(episodes[0].join, "key", episodes[0].join)

    def test_an_app_connect_operation_counts_as_the_episodes_attempt(self):
        # A pre-O-4 export records its attempts as `operation.gatewayConnect`
        # alone: 149 of them on the incident export. The 02:40 episode had two,
        # so reporting no attempt at all contradicts the export.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T02:40:01.670Z", "connected", "reconnecting"),
            app_record("2026-09-28T02:40:24.000Z", "operation.gatewayConnect", "count=0",
                       level="error", outcome="failure", duration_ms=15001,
                       lifecycle_generation=None),
            app_record("2026-09-28T02:40:52.000Z", "operation.gatewayConnect", "count=0",
                       level="error", outcome="failure", duration_ms=15001,
                       lifecycle_generation=None),
            state_change("2026-09-28T02:40:53.337Z", "reconnecting", "connected"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["attempts"], 2, found["evidence"])
        self.assertNotIn("no attempt recorded", self.causes_text(found))
        self.assertIn("durationMs=15001", self.causes_text(found))
        # It names no profile or stage, so it is context rather than this
        # episode's path evidence.
        self.assertEqual(found["cause"], "unknown", found["evidence"])

    def test_the_tolerance_widens_how_far_evidence_reaches(self):
        # A relay-silence record 45 s before the loss: outside the model's own
        # 30 s pad, inside the documented 60 s default. A tolerance above 30 s
        # has to change the result, or the flag does nothing.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T04:05:25.843Z", "connected", "reconnecting"),
            state_change("2026-09-28T04:05:26.843Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T04:04:40.843Z", "connection.inbound-silent", "warning",
                           "Client gw-1 has sent nothing for 25000ms (unansweredPingMs=none)",
                           connectionId="gw-1", peerPath="relay", peerRelay="sfo"),
        ])
        self.assertEqual(self.only_episode(self.run_tool(phone))["cause"], "path")
        narrowed = self.only_episode(
            self.run_tool(phone, extra=["--tolerance-seconds", "10"]))
        self.assertEqual(narrowed["cause"], "unknown", narrowed["evidence"])

    def test_a_resource_warning_in_the_pad_is_not_the_cause(self):
        # The handoff and the doc say a Gateway-wide record counts when it falls
        # inside the episode; a resource warning 25 s after it ended is about
        # whatever the Gateway was doing then.
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T05:00:00.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T05:00:15.000Z", "reconnecting", "connected"),
        ])
        self.gateway([
            gateway_record("2026-09-28T05:00:40.000Z", "gateway.resources", "warning",
                           "Host memory low (hostFreeBytes=100000000)"),
        ])
        found = self.only_episode(self.run_tool(phone))
        self.assertEqual(found["cause"], "unknown", found["evidence"])


class LiveEvidenceTests(TriageFixture):
    """The full run over every fixture, kept as the readable artifact."""

    def test_a_neighbour_episode_is_not_swallowed_by_the_join_tolerance(self):
        phone = self.write("phone.jsonl", [
            state_change("2026-09-28T13:33:10.900Z", "connected", "reconnecting"),
            state_change("2026-09-28T13:33:20.000Z", "reconnecting", "connected"),
            attempt("2026-09-28T13:34:16.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-near"),
            episode("2026-09-28T13:34:05.000Z", "2026-09-28T13:34:17.000Z", 1,
                    "pong_timeout", "connected"),
        ])
        report = self.run_tool(phone)
        self.assertEqual(report["summary"]["episodes"], 2, report["episodes"])
        self.assertEqual([item["cause"] for item in report["episodes"]], ["unknown", "unknown"])

    def test_all_causes_report_and_keep_the_artifact(self):
        phone = self.write("phone.jsonl", [
            attempt("2026-09-28T01:29:59.000Z", 36, "success", "connected", "none",
                    gateway_connection_id="gw-1"),
            attempt("2026-09-28T01:30:05.000Z", 5042, "failure", "hello-receive", "transport"),
            attempt("2026-09-28T01:31:28.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-1"),
            episode("2026-09-28T01:30:00.000Z", "2026-09-28T01:31:28.000Z", 2,
                    "pong_timeout,transport", "connected"),
            attempt("2026-09-28T01:35:00.000Z", 15000, "failure", "transport-open", "timeout",
                    attempt_id="a1"),
            attempt("2026-09-28T01:35:04.000Z", 38, "success", "connected", "none",
                    gateway_connection_id="gw-2", attempt_id="a1"),
            episode("2026-09-28T01:34:55.000Z", "2026-09-28T01:35:04.000Z", 2, "transport",
                    "connected"),
            state_change("2026-09-28T04:05:25.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T04:11:46.000Z", "reconnecting", "connected"),
            state_change("2026-09-28T03:24:45.000Z", "connected", "reconnecting"),
            state_change("2026-09-28T03:30:30.000Z", "reconnecting", "connected"),
            attempt("2026-09-28T02:00:05.000Z", 15000, "failure", "transport-open", "background",
                    foreground=False),
            episode("2026-09-28T02:00:00.000Z", "2026-09-28T02:00:30.000Z", 1, "background",
                    "background"),
        ])
        self.gateway([
            gateway_record("2026-09-28T01:29:59.000Z", "connection.opened", "info",
                           "Client gw-1 connection opened after 9ms", connectionId="gw-1",
                           peerClientId="c1", peerAttemptId="initial"),
            gateway_record("2026-09-28T01:30:20.000Z", "connection.inbound-silent", "warning",
                           "Client gw-1 has sent nothing for 21000ms",
                           connectionId="gw-1", peerPath="relay", peerRelay="sfo"),
            gateway_record("2026-09-28T01:35:04.000Z", "connection.opened", "info",
                           "Client gw-2 connection opened after 12ms", connectionId="gw-2",
                           peerClientId="c2", peerAttemptId="a1"),
            gateway_record("2026-09-28T04:04:59.000Z", "connection.opened", "info",
                           "Client gw-3 connection opened after 9ms", connectionId="gw-3"),
            gateway_record("2026-09-28T04:06:00.000Z", "rpc.completed", "debug",
                           "RPC session.open for client gw-3 completed in 800ms (success)",
                           method="session.open", connectionId="gw-3", outcome="success",
                           durationMs=800),
            gateway_record("2026-09-28T04:06:10.000Z", "connection.closed", "info",
                           "Client gw-3 connection closed after 71000ms", connectionId="gw-3"),
        ])
        # The wrong-label episode needs the live socket to be gw-3.
        with phone.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(attempt("2026-09-28T04:04:59.000Z", 38, "success",
                                            "connected", "none",
                                            gateway_connection_id="gw-3")) + "\n")
        report = self.run_tool(phone)
        causes = [episode["cause"] for episode in report["episodes"]]
        self.assertEqual(causes, ["path", "path", "phone-background", "unknown", "phone-stall"],
                         report["episodes"])
        self.assertEqual(report["summary"]["byCause"]["path"], 2)
        retained = Path(os.environ.get(
            "TRON_TRIAGE_TEST_REPORT",
            Path(tempfile.gettempdir()) / "tron-triage-report.json"))
        retained.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        # The text table is what an operator reads first.
        table = self.run_tool(phone, json_output=False)
        self.assertIn("episodes: 5", table)
        self.assertIn("path=2", table)
        self.assertIn("phone-stall", table)
        retained_text = Path(str(retained) + ".txt")
        retained_text.write_text(table, encoding="utf-8")
        self.assertTrue(retained.is_file())
        self.assertTrue(retained_text.is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
