#!/usr/bin/env python3
"""Live agent harness for RWO-N16 pre-terminal worker retry evidence."""

import argparse
import base64
import datetime as dt
import json
import os
import socket
import sqlite3
import struct
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
DB_PATH = os.path.expanduser("~/.tron/internal/database/tron.sqlite")
AUTH_PATH = os.path.expanduser("~/.tron/profiles/auth.json")
SERVER = "ws://127.0.0.1:9847/engine"
HEALTH = "http://127.0.0.1:9847/health"
DEFAULT_SIM_UDID = os.environ.get("TRON_RWO_SIM_UDID", "booted")
TERMINAL_STOP_REASON = "end_turn"


class RawWebSocket:
    def __init__(self, url, bearer_token):
        parsed = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = parsed.path or "/engine"
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {parsed.hostname}:{parsed.port or 80}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {bearer_token}\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode("utf-8"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("websocket closed during handshake")
            response += chunk
        status = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise RuntimeError(response.decode("utf-8", "replace"))

    def send_json(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", len(payload)))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", len(payload)))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + masked)

    def recv_json(self, timeout=30):
        self.sock.settimeout(timeout)
        first = self.sock.recv(1)
        if not first:
            raise EOFError("websocket closed")
        second = self._recv_exact(1)[0]
        opcode = first[0] & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if second & 0x80 else b""
        payload = self._recv_exact(length)
        if mask:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            raise EOFError(payload)
        if opcode == 0x9:
            self._send_control(0x8A, payload)
            return self.recv_json(timeout)
        return json.loads(payload.decode("utf-8"))

    def request(self, value, timeout=60):
        self.send_json(value)
        request_id = value["id"]
        while True:
            message = self.recv_json(timeout)
            if message.get("id") == request_id:
                return message

    def close(self):
        try:
            self._send_control(0x88, b"")
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass

    def _recv_exact(self, size):
        chunks = []
        remaining = size
        while remaining:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise EOFError("websocket closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _send_control(self, opcode, payload):
        header = bytearray([opcode])
        header.append(0x80 | len(payload))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + masked)


def load_token():
    explicit = os.environ.get("TRON_ENGINE_BEARER_TOKEN")
    if explicit:
        return explicit.removeprefix("Bearer ").strip()
    with open(AUTH_PATH, encoding="utf-8") as handle:
        return json.load(handle)["bearerToken"]


def db_json(query, params=()):
    with sqlite3.connect(DB_PATH, timeout=10) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, params)]


def db_scalar(query, params=()):
    rows = db_json(query, params)
    if not rows:
        return None
    return next(iter(rows[0].values()))


def run_cmd(argv, timeout=60):
    started = dt.datetime.now(dt.UTC).isoformat()
    proc = subprocess.run(
        argv,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return {
        "argv": argv,
        "returncode": proc.returncode,
        "started": started,
        "finished": dt.datetime.now(dt.UTC).isoformat(),
        "output": proc.stdout[-8000:],
    }


def invoke(ws, function_id, payload, request_id, idempotency_key, context=None, timeout=60):
    request = {
        "type": "invoke",
        "id": request_id,
        "functionId": function_id,
        "payload": payload,
        "idempotencyKey": idempotency_key,
    }
    if context:
        request["context"] = context
    return ws.request(request, timeout=timeout)


def child_value(response):
    if not response.get("ok"):
        raise RuntimeError(f"engine error: {response}")
    child = response["result"]["child"]
    if child.get("error"):
        raise RuntimeError(f"child error: {child['error']}")
    return child["value"], child


def ws_hello(label, session_id=None):
    ws = RawWebSocket(SERVER, load_token())
    message = {"type": "hello", "id": label, "protocolVersion": 1}
    if session_id:
        message["sessionId"] = session_id
    ws.send_json(message)
    hello = ws.recv_json(timeout=30)
    if hello.get("type") != "hello.ok":
        raise RuntimeError(hello)
    return ws, hello


def create_session(ws, stamp, model):
    response = invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": f"RWO-N16 pre-terminal worker retry {stamp}",
            "useWorktree": False,
        },
        "create-rwo-n16",
        f"rwo-n16-session-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "RWO-N16", "harness": "agent-live"},
        },
        timeout=60,
    )
    value, child = child_value(response)
    return value["sessionId"], child


def start_fixture(fixture):
    stdout = open(fixture["stdout"], "a", encoding="utf-8")
    cmd = [
        sys.executable,
        str(ROOT / "packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py"),
        "--session-id",
        fixture["sessionId"],
        "--worker-id",
        fixture["workerId"],
        "--function-id",
        fixture["functionId"],
        "--trigger-id",
        fixture["triggerId"],
        "--stream-topic",
        fixture["streamTopic"],
        "--log",
        fixture["log"],
        "--failure-mode",
        "disconnect-on-first-invoke",
        "--reconnect-after-disconnect",
        "--reconnect-delay-ms",
        "50",
        "--heartbeat-interval-ms",
        "1000",
    ]
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=stdout, stderr=subprocess.STDOUT, text=True)
    return proc, stdout, cmd


def stop_fixture(proc, stdout):
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    if stdout is not None:
        stdout.close()


def wait_registration(session_id, worker_id, function_id, trigger_id, timeout=30):
    deadline = time.monotonic() + timeout
    last = []
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT after_revision, subject_kind_json, subject_id, kind_json,
                   owner_worker_id, timestamp
            FROM engine_catalog_changes
            WHERE session_id = ? AND subject_id IN (?, ?, ?)
            ORDER BY after_revision
            """,
            (session_id, worker_id, function_id, trigger_id),
        )
        last = rows
        registered = {
            row["subject_id"]
            for row in rows
            if row["kind_json"] in (
                '"WorkerRegistered"',
                '"FunctionRegistered"',
                '"TriggerRegistered"',
            )
        }
        if {worker_id, function_id, trigger_id}.issubset(registered):
            return rows
        time.sleep(0.25)
    raise TimeoutError(f"worker registration not visible; last={last}")


def exact_prompt(fixture):
    stamp = fixture["stamp"]
    session_id = fixture["sessionId"]
    worker_args = {
        "subscriptionId": fixture["workerSubscriptionId"],
        "topic": fixture["streamTopic"],
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    queue_args = {
        "subscriptionId": fixture["queueSubscriptionId"],
        "topic": "queue.lifecycle",
        "sessionId": session_id,
        "afterCursor": 0,
        "visibility": "session",
    }
    dispatch_args = {
        "triggerId": fixture["triggerId"],
        "deliveryMode": "enqueue",
        "targetIdempotencyKey": f"rwo-n16-target-{stamp}",
        "payload": {"message": "rwo-n16 worker disconnect retry", "nonce": stamp},
    }
    resource_args = {
        "kind": "evidence",
        "scope": "session",
        "sessionId": session_id,
        "resourceId": fixture["resourceId"],
        "payload": {
            "summary": f"RWO-N16 pre-terminal worker disconnect retry evidence {stamp}",
            "source": "agent execute run",
            "resourceRef": fixture["resourceId"],
            "metadata": {
                "sessionId": session_id,
                "workerId": fixture["workerId"],
                "functionId": fixture["functionId"],
                "triggerId": fixture["triggerId"],
                "streamTopic": fixture["streamTopic"],
                "workerSubscriptionId": fixture["workerSubscriptionId"],
                "queueSubscriptionId": fixture["queueSubscriptionId"],
                "receiptId": "<receiptId from step 3>",
                "expectedFirstFailure": "WORKER_DISCONNECTED",
                "expectedRetryAttempts": 1,
            },
        },
    }
    return f"""Use only execute. RWO-N16 pre-terminal worker disconnect retry test. Do not use shell, process, filesystem, web, browser, or non-execute tools. Make exactly these target invocations through execute in order, then report every id and observed state.

The live worker fixture is intentionally configured to disconnect before sending the first target result, then reconnect with the same worker/function/trigger. The engine should fail that claimed queue attempt, mark the queue item ready with attempts incremented, retry it after the worker reconnects, then complete the same receipt.

1. execute target stream::subscribe, operation run, idempotencyKey rwo-n16-worker-sub-{stamp}, arguments {json.dumps(worker_args, separators=(",", ":"))}.
2. execute target stream::subscribe, operation run, idempotencyKey rwo-n16-queue-sub-{stamp}, arguments {json.dumps(queue_args, separators=(",", ":"))}.
3. execute target trigger::dispatch, operation run, idempotencyKey rwo-n16-trigger-dispatch-{stamp}, arguments {json.dumps(dispatch_args, separators=(",", ":"))}.
4. From step 3 capture receiptId. execute target queue::get, operation run, idempotencyKey rwo-n16-queue-get-{stamp}, arguments {{"receiptId":"<receiptId from step 3>"}}. If the status is not completed yet, call queue::get one more time with idempotencyKey rwo-n16-queue-get-retry-{stamp} and the same receiptId.
5. execute target stream::poll, operation run, idempotencyKey rwo-n16-worker-poll-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}","afterCursor":0,"limit":25}}. Confirm a worker event has payload.result.rwoN16Retry=true.
6. execute target stream::poll, operation run, idempotencyKey rwo-n16-queue-poll-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}","afterCursor":0,"limit":50}}. Confirm the same receipt has queue.fail with status ready and attempts 1, then queue.complete with status completed.
7. execute target resource::create, operation run, idempotencyKey rwo-n16-resource-create-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.
8. execute target worker::health, operation run, idempotencyKey rwo-n16-worker-health-{stamp}, arguments {{"workerId":"{fixture["workerId"]}"}}.
9. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n16-worker-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["workerSubscriptionId"]}"}}.
10. execute target stream::unsubscribe, operation run, idempotencyKey rwo-n16-queue-unsubscribe-{stamp}, arguments {{"subscriptionId":"{fixture["queueSubscriptionId"]}"}}.

Final answer requirements: report each execute invocation id, child target invocation id if visible, trigger receiptId, queue final status and attempts, queue.fail and queue.complete evidence, worker retry marker, evidence resourceRef/resourceId/versionId if visible, worker health, and whether any approval was required. Do not invent missing ids; say not visible if an id is not visible."""


def send_prompt(ws, fixture):
    prompt = exact_prompt(fixture)
    before_sequence = db_scalar(
        "SELECT coalesce(max(sequence), -1) FROM events WHERE session_id = ?",
        (fixture["sessionId"],),
    )
    response = invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": fixture["sessionId"],
            "prompt": prompt,
            "source": f"ios-simulator-rwo-n16-{fixture['stamp']}",
        },
        "prompt-rwo-n16",
        f"rwo-n16-agent-prompt-{fixture['stamp']}",
        {
            "sessionId": fixture["sessionId"],
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {"scenario": "RWO-N16", "harness": "agent-live"},
        },
        timeout=60,
    )
    value, child = child_value(response)
    return prompt, before_sequence, value, child


def event_stop_reason(row):
    if row["stop_reason"]:
        return row["stop_reason"]
    try:
        payload = json.loads(row["payload"] or "{}")
    except json.JSONDecodeError:
        return None
    return payload.get("stopReason")


def wait_end_turn(session_id, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    latest = None
    while time.monotonic() < deadline:
        rows = db_json(
            """
            SELECT sequence, type, stop_reason, payload
            FROM events
            WHERE session_id = ?
            ORDER BY sequence
            """,
            (session_id,),
        )
        terminal = [
            row
            for row in rows
            if row["type"] == "stream.turn_end"
            and event_stop_reason(row) == TERMINAL_STOP_REASON
        ]
        if terminal:
            last = terminal[-1]
            later_start = any(
                row["type"] == "stream.turn_start" and row["sequence"] > last["sequence"]
                for row in rows
            )
            if not later_start:
                return last
        latest = rows[-1] if rows else None
        time.sleep(1)
    raise TimeoutError(f"no terminal end_turn for {session_id}; latest={latest}")


def run_terminal_guard(session_id, timeout_seconds):
    proc = subprocess.run(
        [
            sys.executable,
            str(ROOT / "packages/agent/tests/fixtures/session_terminal_guard.py"),
            "--session-id",
            session_id,
            "--wait",
            "--timeout-seconds",
            str(timeout_seconds),
            "--interval-seconds",
            "1",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout_seconds + 30,
    )
    return {"returncode": proc.returncode, "output": proc.stdout.strip()}


def collect(fixture, start_cursor, start_ts):
    session_id = fixture["sessionId"]
    invocations = db_json(
        """
        SELECT invocation_id, function_id, worker_id, parent_invocation_id, trace_id,
               session_id, idempotency_key, replayed_from, succeeded,
               produced_resource_refs_json, substr(result_json, 1, 6000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview, timestamp
        FROM engine_invocations
        WHERE session_id = ?
        ORDER BY timestamp
        """,
        (session_id,),
    )
    queues = db_json(
        """
        SELECT receipt_id, queue, function_id, status, attempts, lease_owner,
               lease_expires_at, trace_id, parent_invocation_id, trigger_id,
               idempotency_key, created_at, updated_at
        FROM engine_queue_items
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    streams = db_json(
        """
        SELECT cursor, topic, visibility, session_id, producer, trace_id,
               parent_invocation_id, created_at, substr(payload_json, 1, 4000) AS payload_preview
        FROM engine_stream_events
        WHERE cursor > ?
          AND (session_id = ? OR topic IN (?, 'queue.lifecycle', 'worker.lifecycle'))
        ORDER BY cursor
        """,
        (start_cursor, session_id, fixture["streamTopic"]),
    )
    events = db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               model_primitive_name, invocation_id, substr(payload, 1, 4000) AS payload_preview
        FROM events
        WHERE session_id = ?
        ORDER BY sequence
        """,
        (session_id,),
    )
    approvals = db_json(
        """
        SELECT approval_id, function_id, status, trace_id, parent_invocation_id,
               idempotency_key, decision_actor_id, decided_at, created_at, updated_at
        FROM engine_approvals
        WHERE session_id = ?
        ORDER BY created_at
        """,
        (session_id,),
    )
    resources = db_json(
        """
        SELECT resource_id, kind, scope_kind, scope_value, lifecycle,
               current_version_id, created_by_invocation_id, trace_id, created_at, updated_at
        FROM engine_resources
        WHERE scope_value = ? OR resource_id = ?
        ORDER BY created_at
        """,
        (session_id, fixture["resourceId"]),
    )
    versions = db_json(
        """
        SELECT version_id, resource_id, parent_version_id, content_hash,
               version_state, created_by_invocation_id, trace_id, created_at,
               substr(payload_json, 1, 3000) AS payload_preview
        FROM engine_resource_versions
        WHERE resource_id IN (
            SELECT resource_id
            FROM engine_resources
            WHERE scope_value = ? OR resource_id = ?
        )
        ORDER BY created_at
        """,
        (session_id, fixture["resourceId"]),
    )
    leases = db_json(
        """
        SELECT lease_id, resource_id, holder_invocation_id, function_id, status,
               acquired_at, expires_at, released_at
        FROM engine_resource_leases
        WHERE holder_invocation_id IN (
            SELECT invocation_id FROM engine_invocations WHERE session_id = ?
        )
        ORDER BY acquired_at
        """,
        (session_id,),
    )
    catalog_changes = db_json(
        """
        SELECT after_revision, subject_kind_json, subject_id, owner_worker_id,
               kind_json, session_id, workspace_id, timestamp
        FROM engine_catalog_changes
        WHERE session_id = ?
          AND (subject_id IN (?, ?, ?) OR owner_worker_id = ?)
        ORDER BY after_revision
        """,
        (
            session_id,
            fixture["workerId"],
            fixture["functionId"],
            fixture["triggerId"],
            fixture["workerId"],
        ),
    )
    logs = db_json(
        """
        SELECT timestamp, level, component, message, session_id, trace_id,
               substr(data, 1, 2500) AS data_preview, error_message
        FROM logs
        WHERE timestamp >= ?
          AND (session_id = ?
               OR trace_id IN (SELECT trace_id FROM engine_invocations WHERE session_id = ?))
        ORDER BY timestamp
        """,
        (start_ts, session_id, session_id),
    )
    failed = [row for row in invocations if row["succeeded"] == 0]
    target_queues = [row for row in queues if row["function_id"] == fixture["functionId"]]
    receipt_ids = [row["receipt_id"] for row in target_queues]
    queue_fail_events = [
        row
        for row in streams
        if '"type":"queue.fail"' in (row["payload_preview"] or "")
        and any(receipt in (row["payload_preview"] or "") for receipt in receipt_ids)
    ]
    queue_complete_events = [
        row
        for row in streams
        if '"type":"queue.complete"' in (row["payload_preview"] or "")
        and any(receipt in (row["payload_preview"] or "") for receipt in receipt_ids)
    ]
    worker_retry_events = [
        row for row in streams if "rwoN16Retry" in (row["payload_preview"] or "")
    ]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    return {
        "invocations": invocations,
        "queues": queues,
        "streams": streams,
        "events": events,
        "approvals": approvals,
        "resources": resources,
        "resourceVersions": versions,
        "resourceLeases": leases,
        "catalogChanges": catalog_changes,
        "logs": logs,
        "summary": {
            "failedInvocationCount": len(failed),
            "failedInvocations": failed,
            "approvalCount": len(approvals),
            "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
            "compactEventCount": len(compact_events),
            "targetQueues": target_queues,
            "queueFailEventCount": len(queue_fail_events),
            "queueCompleteEventCount": len(queue_complete_events),
            "workerRetryEventCount": len(worker_retry_events),
            "workerId": fixture["workerId"],
            "functionId": fixture["functionId"],
            "triggerId": fixture["triggerId"],
            "resourceId": fixture["resourceId"],
        },
    }


def run_harness(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    namespace = f"rwo_n16_agent_{stamp}"
    run_log = f"/tmp/rwo_n16_agent_run_{stamp}.json"
    fixture = {
        "stamp": stamp,
        "workerId": f"rwo-n16-agent-worker-{stamp}",
        "functionId": f"{namespace}::queued_echo",
        "triggerId": f"manual:{namespace}.queued_echo",
        "streamTopic": f"{namespace}.worker.events",
        "workerSubscriptionId": f"rwo-n16-agent-worker-sub-{stamp}",
        "queueSubscriptionId": f"rwo-n16-agent-queue-sub-{stamp}",
        "resourceId": f"evidence:rwo-n16-agent:{stamp}",
        "log": f"/tmp/rwo_n16_agent_worker_fixture_{stamp}.jsonl",
        "stdout": f"/tmp/rwo_n16_agent_worker_fixture_{stamp}.stdout.log",
        "screenshot": f"/tmp/rwo_n16_{stamp}_old_simulator.png",
        "sessionId": None,
    }
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "fixture": fixture,
        "serverHealthBefore": run_cmd(["curl", "-fsS", HEALTH], timeout=10),
        "startCursor": db_scalar("SELECT coalesce(max(cursor), 0) FROM engine_stream_events"),
        "startTimestamp": dt.datetime.now(dt.UTC).isoformat(),
    }
    ws = None
    fixture_proc = None
    fixture_stdout = None
    try:
        ws, hello = ws_hello("rwo-n16-hello")
        result["hello"] = hello
        session_id, create_child = create_session(ws, stamp, args.model)
        fixture["sessionId"] = session_id
        result["sessionId"] = session_id
        result["createChild"] = create_child
        fixture_proc, fixture_stdout, fixture_cmd = start_fixture(fixture)
        result["fixtureCommand"] = fixture_cmd
        result["registration"] = wait_registration(
            session_id,
            fixture["workerId"],
            fixture["functionId"],
            fixture["triggerId"],
            timeout=30,
        )
        prompt, before_sequence, prompt_value, prompt_child = send_prompt(ws, fixture)
        result["prompt"] = prompt
        result["beforeSequence"] = before_sequence
        result["promptValue"] = prompt_value
        result["promptChild"] = prompt_child
        result["terminalEvent"] = wait_end_turn(session_id, args.timeout_seconds)
    finally:
        stop_fixture(fixture_proc, fixture_stdout)
        if ws is not None:
            ws.close()
    if fixture["sessionId"]:
        result["terminalGuard"] = run_terminal_guard(
            fixture["sessionId"],
            min(args.timeout_seconds, 180),
        )
        result["simulatorOpen"] = run_cmd(
            ["xcrun", "simctl", "openurl", args.sim_udid, f"tron://session/{fixture['sessionId']}"],
            timeout=30,
        )
        time.sleep(args.screenshot_delay_seconds)
        result["simulatorScreenshot"] = {
            "path": fixture["screenshot"],
            "result": run_cmd(
                ["xcrun", "simctl", "io", args.sim_udid, "screenshot", fixture["screenshot"]],
                timeout=30,
            ),
        }
        result["serverHealthAfter"] = run_cmd(["curl", "-fsS", HEALTH], timeout=10)
        result["db"] = collect(fixture, result["startCursor"], result["startTimestamp"])
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "sessionId": result.get("sessionId"),
        "fixtureLog": fixture["log"],
        "screenshot": fixture["screenshot"],
        "terminalGuard": result.get("terminalGuard"),
        "dbSummary": result.get("db", {}).get("summary"),
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    guard = result.get("terminalGuard") or {}
    if guard.get("returncode") != 0:
        return 2
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="claude-sonnet-4-20250514")
    parser.add_argument("--sim-udid", default=DEFAULT_SIM_UDID)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--screenshot-delay-seconds", type=float, default=2.0)
    return parser.parse_args(argv)


def main(argv):
    return run_harness(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
