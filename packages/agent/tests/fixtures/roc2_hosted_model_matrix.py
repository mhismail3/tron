#!/usr/bin/env python3
"""Live hosted-model matrix harness for ROC-2 scorecard evidence."""

import argparse
import base64
import datetime as dt
import json
import os
import re
import socket
import sqlite3
import struct
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rwo_n16_live_agent_harness as n16

ROOT = n16.ROOT
DB_PATH = os.path.expanduser("~/.tron/internal/database/tron.sqlite")
AUTH_PATH = os.path.expanduser("~/.tron/profiles/auth.json")
SERVER = "ws://127.0.0.1:9847/engine"
HEALTH = "http://127.0.0.1:9847/health"
BASE_MODELS = ["claude-sonnet-4-6", "gpt-5.5"]
TERMINAL_STOP_REASON = "end_turn"


def configure_from_shared_runtime():
    global DB_PATH, AUTH_PATH, SERVER, HEALTH
    DB_PATH = n16.DB_PATH
    AUTH_PATH = n16.AUTH_PATH
    SERVER = n16.SERVER
    HEALTH = n16.HEALTH


class RawWebSocket:
    def __init__(self, url, bearer_token):
        parsed = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {parsed.path or '/engine'} HTTP/1.1\r\n"
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
        self.sock.close()

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
        header = bytearray([opcode, 0x80 | len(payload)])
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


def ws_hello(label):
    ws = RawWebSocket(SERVER, load_token())
    ws.send_json({"type": "hello", "id": label, "protocolVersion": 1})
    hello = ws.recv_json(timeout=30)
    if hello.get("type") != "hello.ok":
        raise RuntimeError(hello)
    return ws, hello


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


def list_models(ws):
    response = invoke(
        ws,
        "model::list",
        {},
        "roc2-model-list",
        "roc2-model-list",
        {"authorityScopes": ["model.read"], "runtimeMetadata": {"scenario": "ROC-2"}},
        timeout=60,
    )
    value, _ = child_value(response)
    return value.get("models") or value.get("items") or []


def current_gemini_model(models):
    google = [m for m in models if m.get("provider") == "google" and str(m.get("id", "")).startswith("gemini-")]
    active = [m for m in google if not (m.get("isRetired") or m.get("retired"))]
    recommended = [m for m in active if m.get("recommended")]
    candidates = recommended or active or google
    if not candidates:
        raise RuntimeError("model::list returned no Gemini models")
    candidates.sort(key=lambda m: (m.get("sortOrder", 9999), m.get("id", "")))
    return candidates[0]["id"]


def create_session(ws, model, stamp):
    response = invoke(
        ws,
        "session::create",
        {
            "workingDirectory": str(ROOT),
            "model": model,
            "title": f"ROC-2 hosted model matrix {model} {stamp}",
            "useWorktree": False,
        },
        f"roc2-create-{model}",
        f"roc2-create-{model}-{stamp}",
        {
            "authorityScopes": ["session.write"],
            "runtimeMetadata": {"scenario": "ROC-2", "harness": "hosted-model-matrix"},
        },
        timeout=60,
    )
    value, child = child_value(response)
    return value["sessionId"], child


def safe_model_label(model):
    return re.sub(r"[^a-zA-Z0-9_.:-]+", "-", model)


def exact_prompt(session_id, model, stamp, resource_id):
    resource_args = {
        "kind": "evidence",
        "resourceId": resource_id,
        "scope": "session",
        "sessionId": session_id,
        "payload": {
            "summary": f"ROC-2 hosted model matrix evidence for {model} {stamp}",
            "marker": f"ROC-2 {model} {stamp}",
            "model": model,
            "readSource": "README.md",
            "expectedReadLines": "1-3",
            "scenario": "ROC-2",
        },
    }
    return f"""Use only execute. ROC-2 hosted model matrix marker {stamp} for model {model}.

Do not use shell, process, web, browser, direct filesystem tools, direct resource tools, or any non-execute tool. Make exactly these two target invocations through execute, in order:

1. execute target filesystem::read_file, operation run, idempotencyKey roc2-read-{stamp}, arguments {{"path":"README.md","startLine":1,"endLine":3}}.
2. execute target resource::create, operation run, idempotencyKey roc2-resource-{stamp}, arguments {json.dumps(resource_args, separators=(",", ":"))}.

Final answer requirements: include the marker ROC-2 {model} {stamp}, say whether README.md was read, report the resourceId {resource_id}, and say whether approval was required. Do not perform any extra capability calls."""


def send_prompt(ws, session_id, model, stamp, resource_id):
    prompt = exact_prompt(session_id, model, stamp, resource_id)
    response = invoke(
        ws,
        "agent::prompt",
        {
            "sessionId": session_id,
            "prompt": prompt,
            "source": f"roc2-hosted-model-matrix-{stamp}",
        },
        f"roc2-prompt-{model}",
        f"roc2-prompt-{model}-{stamp}",
        {
            "sessionId": session_id,
            "authorityScopes": ["session.write", "session.read", "agent.read", "agent.write"],
            "runtimeMetadata": {"scenario": "ROC-2", "harness": "hosted-model-matrix"},
        },
        timeout=60,
    )
    value, child = child_value(response)
    return prompt, value, child


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


def collect(session_id, resource_id, start_ts):
    invocations = db_json(
        """
        SELECT invocation_id, function_id, worker_id, parent_invocation_id, trace_id,
               session_id, idempotency_key, replayed_from, succeeded,
               produced_resource_refs_json, substr(result_json, 1, 5000) AS result_preview,
               substr(error_json, 1, 3000) AS error_preview, timestamp
        FROM engine_invocations
        WHERE session_id = ? AND timestamp >= ?
        ORDER BY timestamp
        """,
        (session_id, start_ts),
    )
    events = db_json(
        """
        SELECT sequence, type, timestamp, model, provider_type, stop_reason,
               model_primitive_name, invocation_id, substr(payload, 1, 3000) AS payload_preview
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
        WHERE session_id = ? AND created_at >= ?
        ORDER BY created_at
        """,
        (session_id, start_ts),
    )
    resources = db_json(
        """
        SELECT resource_id, kind, scope_kind, scope_value, lifecycle,
               current_version_id, created_by_invocation_id, trace_id, created_at, updated_at
        FROM engine_resources
        WHERE (scope_value = ? OR resource_id = ?) AND created_at >= ?
        ORDER BY created_at
        """,
        (session_id, resource_id, start_ts),
    )
    versions = db_json(
        """
        SELECT version_id, resource_id, parent_version_id, content_hash,
               version_state, created_by_invocation_id, trace_id, created_at,
               substr(payload_json, 1, 2500) AS payload_preview
        FROM engine_resource_versions
        WHERE resource_id IN (
            SELECT resource_id
            FROM engine_resources
            WHERE scope_value = ? OR resource_id = ?
        )
        ORDER BY created_at
        """,
        (session_id, resource_id),
    )
    logs = db_json(
        """
        SELECT timestamp, level, component, message, session_id, trace_id,
               substr(data, 1, 2000) AS data_preview, error_message
        FROM logs
        WHERE timestamp >= ?
          AND (session_id = ?
               OR trace_id IN (SELECT trace_id FROM engine_invocations WHERE session_id = ?))
        ORDER BY timestamp
        """,
        (start_ts, session_id, session_id),
    )
    execute_ids = {
        row["invocation_id"]
        for row in invocations
        if row["function_id"] == "capability::execute"
    }
    children = [
        row
        for row in invocations
        if row["parent_invocation_id"] in execute_ids
    ]
    failed = [row for row in invocations if row["succeeded"] == 0]
    error_logs = [
        row
        for row in logs
        if str(row["level"]).lower() in {"error", "fatal"}
    ]
    compact_events = [row for row in events if row["type"].startswith("compact.")]
    target_child_ids = {
        row["function_id"]: row
        for row in children
        if row["function_id"] in {"filesystem::read_file", "resource::create"}
    }
    model_events = [
        {
            "sequence": row["sequence"],
            "type": row["type"],
            "model": row["model"],
            "providerType": row["provider_type"],
            "modelPrimitiveName": row["model_primitive_name"],
            "invocationId": row["invocation_id"],
        }
        for row in events
        if row["model"] or row["provider_type"] or row["model_primitive_name"]
    ]
    summary = {
        "invocationCount": len(invocations),
        "executeCount": len(execute_ids),
        "executeChildFunctions": [row["function_id"] for row in children],
        "targetChildInvocations": target_child_ids,
        "failedInvocationCount": len(failed),
        "approvalCount": len(approvals),
        "pendingApprovals": [row for row in approvals if row["status"] == "pending"],
        "resourceIds": [row["resource_id"] for row in resources],
        "resourceVersionCount": len(versions),
        "errorLogCount": len(error_logs),
        "compactEventCount": len(compact_events),
        "modelEvents": model_events,
    }
    return {
        "invocations": invocations,
        "events": events,
        "approvals": approvals,
        "resources": resources,
        "resourceVersions": versions,
        "logs": logs,
        "summary": summary,
    }


def validate_model_result(model, resource_id, db):
    summary = db["summary"]
    problems = []
    if summary["executeCount"] < 2:
        problems.append(f"{model}: expected at least 2 capability::execute invocations")
    for target in ("filesystem::read_file", "resource::create"):
        row = summary["targetChildInvocations"].get(target)
        if not row:
            problems.append(f"{model}: missing execute child {target}")
        elif row["succeeded"] != 1:
            problems.append(f"{model}: execute child {target} did not succeed")
    if summary["failedInvocationCount"] != 0:
        problems.append(f"{model}: failed invocation count {summary['failedInvocationCount']}")
    if summary["pendingApprovals"]:
        problems.append(f"{model}: pending approvals remain")
    if resource_id not in summary["resourceIds"]:
        problems.append(f"{model}: evidence resource {resource_id} not found")
    if summary["resourceVersionCount"] < 1:
        problems.append(f"{model}: no resource version rows")
    if summary["errorLogCount"] != 0:
        problems.append(f"{model}: error/fatal log count {summary['errorLogCount']}")
    if summary["compactEventCount"] != 0:
        problems.append(f"{model}: compact event count {summary['compactEventCount']}")
    return problems


def run_matrix(args):
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    run_log = f"/tmp/roc2_hosted_model_matrix_{stamp}.json"
    isolated_server = n16.maybe_start_isolated_server(args, stamp, "roc2")
    configure_from_shared_runtime()
    result = {
        "stamp": stamp,
        "runLog": run_log,
        "serverMode": "current_user" if args.use_current_server else "isolated",
        "isolatedServer": n16.public_server_info(isolated_server),
        "serverHealthBefore": run_cmd(["curl", "-fsS", HEALTH], timeout=10),
        "models": {},
        "validationProblems": [],
    }
    ws = None
    try:
        ws, hello = ws_hello("roc2-hello")
        result["hello"] = hello
        catalog = list_models(ws)
        result["catalog"] = {
            "modelCount": len(catalog),
            "filtered": [
                {
                    "id": m.get("id"),
                    "provider": m.get("provider"),
                    "name": m.get("name"),
                    "recommended": m.get("recommended"),
                    "sortOrder": m.get("sortOrder"),
                    "isRetired": m.get("isRetired") or m.get("retired"),
                    "contextWindow": m.get("contextWindow"),
                }
                for m in catalog
                if m.get("id") in BASE_MODELS or str(m.get("id", "")).startswith("gemini-")
            ],
        }
        gemini_model = args.gemini_model or current_gemini_model(catalog)
        models = args.models or [*BASE_MODELS, gemini_model]
        result["selectedModels"] = models
        for index, model in enumerate(models, start=1):
            model_stamp = f"{stamp}-{index}"
            model_key = safe_model_label(model)
            resource_id = f"evidence:roc2:{model_key}:{model_stamp}"
            start_ts = dt.datetime.now(dt.UTC).isoformat()
            session_id, create_child = create_session(ws, model, model_stamp)
            prompt, prompt_value, prompt_child = send_prompt(
                ws,
                session_id,
                model,
                model_stamp,
                resource_id,
            )
            terminal = wait_end_turn(session_id, args.timeout_seconds)
            db = collect(session_id, resource_id, start_ts)
            problems = validate_model_result(model, resource_id, db)
            result["validationProblems"].extend(problems)
            result["models"][model] = {
                "sessionId": session_id,
                "resourceId": resource_id,
                "startTimestamp": start_ts,
                "createChild": create_child,
                "prompt": prompt,
                "promptValue": prompt_value,
                "promptChild": prompt_child,
                "terminalEvent": terminal,
                "db": db,
                "validationProblems": problems,
            }
    finally:
        if ws is not None:
            ws.close()
    result["serverHealthAfter"] = run_cmd(["curl", "-fsS", HEALTH], timeout=10)
    if isolated_server is not None:
        result["isolatedServerStop"] = n16.stop_isolated_server(isolated_server["process"])
    with open(run_log, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    summary = {
        "runLog": run_log,
        "selectedModels": result.get("selectedModels"),
        "validationProblems": result["validationProblems"],
        "models": {
            model: {
                "sessionId": data["sessionId"],
                "resourceId": data["resourceId"],
                "dbSummary": data["db"]["summary"],
            }
            for model, data in result["models"].items()
        },
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 1 if result["validationProblems"] else 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", dest="models", action="append", help="Model to test; may be repeated.")
    parser.add_argument("--gemini-model", help="Gemini model to use instead of the current model::list recommendation.")
    parser.add_argument("--timeout-seconds", type=int, default=900)
    n16.add_runtime_args(parser)
    return parser.parse_args(argv)


def main(argv):
    return run_matrix(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
