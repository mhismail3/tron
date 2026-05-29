#!/usr/bin/env python3
"""Deterministic live worker fixture for the RWO-N7 scorecard scenario."""

import argparse
import base64
import json
import os
import select
import signal
import socket
import ssl
import struct
import sys
import time
import urllib.parse

DEFAULT_ENDPOINT = "ws://127.0.0.1:9847/engine/workers"
DEFAULT_AUTH_PATH = os.path.expanduser("~/.tron/profiles/auth.json")
DEFAULT_WORKER_ID = "rwo-n7-fixture-worker"
DEFAULT_FUNCTION_ID = "rwo_n7::echo"
DEFAULT_TRIGGER_ID = "manual:rwo_n7.echo"

STOP = False


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def namespace_from_function(function_id):
    return function_id.split("::", 1)[0] if "::" in function_id else function_id


def engine_visibility(visibility):
    return {"session": "Session", "workspace": "Workspace", "system": "System"}[visibility]


def load_bearer_token(path):
    explicit = os.environ.get("TRON_ENGINE_BEARER_TOKEN")
    if explicit:
        return explicit.removeprefix("Bearer ").strip()
    with open(path, "r", encoding="utf-8") as handle:
        token = json.load(handle).get("bearerToken")
    if not token:
        raise RuntimeError(f"{path} does not contain bearerToken")
    return token


def connect_websocket(endpoint, token):
    endpoint = endpoint.strip()
    if "://" not in endpoint:
        endpoint = "ws://" + endpoint
    url = urllib.parse.urlparse(endpoint)
    if url.scheme not in ("ws", "wss"):
        raise RuntimeError("endpoint must use ws:// or wss://")
    host = url.hostname or "127.0.0.1"
    port = url.port or (443 if url.scheme == "wss" else 80)
    path = url.path or "/engine/workers"
    if path.rstrip("/") == "/engine":
        path = "/engine/workers"
    elif path.rstrip("/") != "/engine/workers":
        raise RuntimeError(f"endpoint must target /engine/workers, got {path}")
    if url.query:
        path += "?" + url.query

    raw = socket.create_connection((host, port), timeout=10)
    if url.scheme == "wss":
        raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {token}\r\n"
        "\r\n"
    ).encode("ascii")
    raw.sendall(request)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = raw.recv(4096)
        if not chunk:
            raise RuntimeError("websocket closed during handshake")
        response += chunk
    status = response.split(b"\r\n", 1)[0]
    if b" 101 " not in status:
        raise RuntimeError(response.decode("utf-8", "replace"))
    raw.setblocking(True)
    return raw


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("websocket closed")
        data += chunk
    return data


def send_frame(sock, opcode, payload=b""):
    header = bytearray([0x80 | opcode])
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
    sock.sendall(header + masked)


def send_json(sock, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    send_frame(sock, 0x1, payload)


def recv_json(sock):
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    masked = bool(second & 0x80)
    mask = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length)
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if opcode == 0x8:
        raise EOFError("websocket close frame")
    if opcode == 0x9:
        send_frame(sock, 0xA)
        return None
    if opcode != 0x1:
        return None
    return json.loads(payload.decode("utf-8"))


def scoped_provenance(args):
    return {
        "created_by": "system",
        "source": "rwo-n7-live-worker-fixture",
        "session_id": args.session_id,
        "workspace_id": args.workspace_id,
    }


def worker_token(args):
    namespace = namespace_from_function(args.function_id)
    return {
        "pluginId": f"session_generated.{args.worker_id}",
        "namespaceClaims": [namespace],
        "authorityGrantId": "worker-runtime",
        "authorityGrantRevision": 1,
        "authorityGrantHash": "loopback-bootstrap",
        "resourceSelectors": ["*"],
        "visibilityCeiling": args.visibility,
        "trustTier": "session_generated",
        "sessionId": args.session_id,
        "workspaceId": args.workspace_id,
        "expiresAt": None,
        "signatureStatus": "session_scoped",
    }


def worker_definition(args, token):
    namespace = namespace_from_function(args.function_id)
    return {
        "id": args.worker_id,
        "revision": 1,
        "kind": "External",
        "lifecycle": "Ready",
        "owner_actor": "rwo-n7-fixture-owner",
        "authority_grant": token["authorityGrantId"],
        "namespace_claims": [namespace],
        "visibility": engine_visibility(args.visibility),
        "provenance": scoped_provenance(args),
    }


def function_definition(args):
    namespace = namespace_from_function(args.function_id)
    return {
        "id": args.function_id,
        "revision": 1,
        "owner_worker": args.worker_id,
        "description": "RWO-N7 deterministic live worker echo fixture",
        "request_schema": {"type": "object", "additionalProperties": True},
        "response_schema": {"type": "object", "additionalProperties": True},
        "opaque_response": False,
        "tags": ["rwo-n7", "live-worker", "deterministic-fixture"],
        "visibility": engine_visibility(args.visibility),
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": None,
        "resource_lease": None,
        "compensation": None,
        "output_contract": {"kind": "none"},
        "required_authority": {"scopes": [], "approval_required": False},
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": scoped_provenance(args),
        "metadata": {
            "contractId": args.function_id,
            "implementationId": f"session_generated.{namespace}.rwo_n7_echo",
            "pluginId": f"session_generated.{args.worker_id}",
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "external", "deliveryModes": ["Sync"]},
            "examples": [{"payload": {"message": "rwo-n7"}}],
            "modelPrimitiveName": "rwo_n7_echo",
            "streamTopics": ["worker.lifecycle"],
        },
    }


def trigger_definition(args):
    return {
        "id": args.trigger_id,
        "revision": 1,
        "owner_worker": args.worker_id,
        "trigger_type": "manual",
        "target_function": args.function_id,
        "target_revision": None,
        "config": {"purpose": "RWO-N7 trigger metadata visibility fixture"},
        "delivery_mode": "Sync",
        "authority_grant": "worker-runtime",
        "idempotency_key_strategy": None,
        "max_depth": 1,
        "visibility": engine_visibility(args.visibility),
        "provenance": scoped_provenance(args),
    }


def log_event(handle, event, **fields):
    record = {"event": event, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **fields}
    line = json.dumps(record, sort_keys=True)
    print(line, flush=True)
    if handle:
        handle.write(line + "\n")
        handle.flush()


def summarize_protocol_message(args, message):
    message_type = message.get("type")
    if message_type == "catalog_snapshot":
        functions = message.get("functions") or []
        triggers = message.get("triggers") or []
        return {
            "type": message_type,
            "functionCount": len(functions),
            "triggerCount": len(triggers),
            "containsFunction": any(function.get("id") == args.function_id for function in functions),
            "containsTrigger": any(trigger.get("id") == args.trigger_id for trigger in triggers),
        }
    if message_type == "catalog_change":
        return {
            "type": message_type,
            "kind": message.get("kind"),
            "subjectId": message.get("subjectId"),
            "ownerWorker": message.get("ownerWorker"),
            "catalogRevision": message.get("catalogRevision"),
        }
    return {"type": message_type}


def send_heartbeat(sock, args, sequence, log_handle):
    send_json(sock, {"type": "heartbeat", "workerId": args.worker_id, "sequence": sequence})
    log_event(log_handle, "heartbeat_sent", workerId=args.worker_id, sequence=sequence)


def run_fixture(args):
    token = worker_token(args)
    bearer = load_bearer_token(args.auth_path)
    log_handle = open(args.log, "a", encoding="utf-8") if args.log else None
    sock = None
    heartbeat_sequence = 0
    try:
        sock = connect_websocket(args.endpoint, bearer)
        log_event(log_handle, "connected", endpoint=args.endpoint, workerId=args.worker_id)
        send_json(sock, {
            "type": "hello",
            "protocolVersion": 1,
            "worker": worker_definition(args, token),
            "loopbackOnly": True,
            "identity": {
                "workerId": args.worker_id,
                "workerName": "RWO-N7 live worker fixture",
                "workerVersion": "rwo-n7-1",
                "sandboxed": False,
            },
            "authPolicy": "loopback_bearer",
            "registrationMode": "volatile",
            "defaultVisibility": args.visibility,
            "sessionId": args.session_id,
            "workspaceId": args.workspace_id,
            "heartbeatIntervalMs": args.heartbeat_interval_ms,
            "supportedCapabilities": [args.function_id, args.trigger_id],
            "workerToken": token,
        })
        send_json(sock, {
            "type": "register_function",
            "definition": function_definition(args),
            "defaultVisibility": engine_visibility(args.visibility),
        })
        send_json(sock, {"type": "register_trigger", "definition": trigger_definition(args)})
        log_event(
            log_handle,
            "registration_sent",
            workerId=args.worker_id,
            functionId=args.function_id,
            triggerId=args.trigger_id,
            visibility=args.visibility,
        )

        next_heartbeat = 0.0
        while not STOP:
            now = time.monotonic()
            if now >= next_heartbeat:
                heartbeat_sequence += 1
                send_heartbeat(sock, args, heartbeat_sequence, log_handle)
                next_heartbeat = now + args.heartbeat_interval_ms / 2000

            readable, _, _ = select.select([sock], [], [], 0.25)
            if not readable:
                continue
            message = recv_json(sock)
            if message is None:
                continue
            message_type = message.get("type")
            if message_type == "error":
                log_event(log_handle, "server_error", message=message.get("message"))
                raise RuntimeError(message.get("message", "server_error"))
            if message_type in ("catalog_snapshot", "catalog_change"):
                log_event(log_handle, "worker_protocol_event", message=summarize_protocol_message(args, message))
                continue
            if message_type == "invoke":
                invocation_id = message["invocationId"]
                if message.get("functionId") != args.function_id:
                    send_json(sock, {
                        "type": "result",
                        "invocationId": invocation_id,
                        "result": None,
                        "error": {"message": "unknown function"},
                    })
                    log_event(log_handle, "invoke_rejected", invocationId=invocation_id)
                    continue
                payload = message.get("payload", {})
                result = {
                    "rwoN7Fixture": True,
                    "workerId": args.worker_id,
                    "functionId": args.function_id,
                    "invocationId": invocation_id,
                    "traceId": message.get("traceId"),
                    "sessionId": message.get("sessionId"),
                    "echo": payload,
                }
                send_json(sock, {
                    "type": "result",
                    "invocationId": invocation_id,
                    "result": result,
                    "error": None,
                })
                log_event(log_handle, "invoke_completed", invocationId=invocation_id, result=result)
                continue
            if message_type == "disconnect":
                log_event(log_handle, "server_disconnect", message=message)
                return
            log_event(log_handle, "unhandled_message", message=message)
    finally:
        if sock is not None:
            try:
                send_json(sock, {
                    "type": "disconnect",
                    "workerId": args.worker_id,
                    "reason": "fixture stopped",
                })
                log_event(log_handle, "disconnect_sent", workerId=args.worker_id)
                send_frame(sock, 0x8)
            except Exception as error:
                log_event(log_handle, "disconnect_error", error=str(error))
            try:
                sock.close()
            except Exception:
                pass
        if log_handle:
            log_handle.close()


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=os.environ.get("TRON_ENGINE_WORKER_ENDPOINT", DEFAULT_ENDPOINT))
    parser.add_argument("--auth-path", default=DEFAULT_AUTH_PATH)
    parser.add_argument("--worker-id", default=DEFAULT_WORKER_ID)
    parser.add_argument("--function-id", default=DEFAULT_FUNCTION_ID)
    parser.add_argument("--trigger-id", default=DEFAULT_TRIGGER_ID)
    parser.add_argument("--visibility", choices=["session", "workspace", "system"], default="system")
    parser.add_argument("--session-id")
    parser.add_argument("--workspace-id")
    parser.add_argument("--heartbeat-interval-ms", type=int, default=5000)
    parser.add_argument("--log")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    args = parse_args(argv)
    if args.visibility == "session" and not args.session_id:
        raise SystemExit("--session-id is required for session visibility")
    if args.visibility == "workspace" and not args.workspace_id:
        raise SystemExit("--workspace-id is required for workspace visibility")
    if args.self_test:
        token = worker_token(args)
        heartbeat = {"type": "heartbeat", "workerId": args.worker_id, "sequence": 1}
        assert heartbeat["sequence"] == 1
        assert function_definition(args)["metadata"]["contractId"] == args.function_id
        assert trigger_definition(args)["target_function"] == args.function_id
        assert worker_definition(args, token)["authority_grant"] == token["authorityGrantId"]
        print(json.dumps({"ok": True, "functionId": args.function_id, "triggerId": args.trigger_id}))
        return 0
    run_fixture(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
